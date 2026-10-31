import CoreLocation
import Foundation

struct DeviceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }

    /// Reads and frees a message from the C layer.
    static func take(_ pointer: UnsafeMutablePointer<CChar>?, fallback: String) -> String {
        guard let pointer else { return fallback }
        let text = String(cString: pointer)
        wp_string_free(pointer)
        return text.isEmpty ? fallback : friendly(text)
    }

    static func friendly(_ text: String) -> String {
        let lowered = text.lowercased()
        if lowered.contains("could not connect to the iphone") || lowered.contains("connection refused")
            || lowered.contains("socket io failed") || lowered.contains("timed out") {
            return "Waypoint could not reach this iPhone. Turn on LocalDevVPN, stay on Wi-Fi, and try again."
        }
        if lowered.contains("pairing file") && lowered.contains("read") {
            return "The pairing file is missing or damaged. Pair this iPhone again in Setup."
        }
        if lowered.contains("verify") || lowered.contains("pair-verify") || lowered.contains("not paired") {
            return "This iPhone no longer trusts Waypoint's pairing. Pair again in Setup."
        }
        if lowered.contains("developer mode") || lowered.contains("developermode") {
            return "Developer Mode is off. Turn it on in Settings › Privacy & Security › Developer Mode."
        }
        return text
    }
}

struct RouteProgress: Equatable {
    var routeName: String
    var travelledKm: Double
    var totalKm: Double
    var remainingSeconds: Double
    var finished: Bool
}

@MainActor
final class DeviceService: ObservableObject {
    enum Status: Equatable {
        case notPaired
        case disconnected
        case working(String)
        case connected      // tunnel up, developer support not mounted yet
        case ready          // can simulate
        case failed(String)
    }

    @Published private(set) var status: Status = .disconnected
    @Published private(set) var deviceName = ""
    @Published private(set) var iosVersion = ""
    @Published private(set) var simulated: Place?
    @Published private(set) var routeProgress: RouteProgress?
    @Published private(set) var routePath: [CLLocationCoordinate2D] = []

    /// Device address on the loopback VPN; LocalDevVPN uses 10.7.0.1.
    @Published var deviceIP: String = UserDefaults.standard.string(forKey: "deviceIP") ?? "10.7.0.1" {
        didSet { UserDefaults.standard.set(deviceIP, forKey: "deviceIP") }
    }
    /// 0 = discover automatically.
    @Published var portOverride: Int = UserDefaults.standard.integer(forKey: "portOverride") {
        didSet { UserDefaults.standard.set(portOverride, forKey: "portOverride") }
    }

    var store: PlaceStore?

    private let queue = DispatchQueue(label: "waypoint.device", qos: .userInitiated)
    private var session: OpaquePointer?          // touched only on `queue`
    private var refreshTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?
    private var holdingKeepAlive = false

    var hasPairingFile: Bool { FileManager.default.fileExists(atPath: AppPaths.pairingFile.path) }
    var isBusy: Bool { if case .working = status { return true }; return false }
    var isSimulating: Bool { simulated != nil || routeProgress != nil }

    init() {
        wp_init_logging(AppPaths.logFile.path)
        status = hasPairingFile ? .disconnected : .notPaired
        NotificationCenter.default.addObserver(forName: .waypointPaired, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = .disconnected
                try? await self.ensureReady()
            }
        }
    }

    // MARK: Pairing file

    func importPairingFile(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).plist")
        try data.write(to: staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        var error: UnsafeMutablePointer<CChar>?
        guard wp_pairing_file_check(staging.path, &error) == 0 else {
            throw DeviceError(DeviceError.take(error, fallback: "This is not a valid pairing file"))
        }
        try? FileManager.default.removeItem(at: AppPaths.pairingFile)
        try data.write(to: AppPaths.pairingFile, options: .completeFileProtectionUntilFirstUserAuthentication)
        Task { await disconnect() }
        status = .disconnected
    }

    func forgetPairing() async {
        await clearLocation(silently: true)
        await disconnect()
        try? FileManager.default.removeItem(at: AppPaths.pairingFile)
        status = .notPaired
    }

    // MARK: Connection

    private func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func call(_ fallback: String, _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32) throws {
        var error: UnsafeMutablePointer<CChar>?
        if body(&error) != 0 { throw DeviceError(DeviceError.take(error, fallback: fallback)) }
        if let error { wp_string_free(error) }
    }

    func disconnect() async {
        _ = try? await onQueue {
            if let session = self.session { wp_session_free(session) }
            self.session = nil
        }
        status = hasPairingFile ? .disconnected : .notPaired
    }

    /// Connects and mounts developer support if needed. Safe to call often.
    func ensureReady() async throws {
        guard hasPairingFile else {
            status = .notPaired
            throw DeviceError("Pair this iPhone first in the Setup tab.")
        }
        if status == .ready, try await sessionAlive() { return }
        do {
            try await connect()
            try await prepare()
        } catch {
            status = .failed(error.localizedDescription)
            throw error
        }
    }

    private func sessionAlive() async throws -> Bool {
        try await onQueue { self.session != nil }
    }

    private func connect() async throws {
        status = .working("Finding this iPhone…")
        let port = portOverride > 0 ? UInt16(clamping: portOverride) : await PortResolver.resolve()
        status = .working("Connecting…")
        let ip = deviceIP.trimmingCharacters(in: .whitespaces)
        let info: (String, String) = try await onQueue {
            if let old = self.session { wp_session_free(old) }
            self.session = nil
            var newSession: OpaquePointer?
            try Self.call("Could not connect to the iPhone") {
                wp_session_connect(ip, port, "Waypoint", AppPaths.pairingFile.path, &newSession, $0)
            }
            self.session = newSession
            func value(_ key: String) -> String {
                var output: UnsafeMutablePointer<CChar>?
                var error: UnsafeMutablePointer<CChar>?
                guard wp_session_get_string(newSession, key, &output, &error) == 0, let output else {
                    if let error { wp_string_free(error) }
                    return ""
                }
                defer { wp_string_free(output) }
                return String(cString: output)
            }
            return (value("DeviceName"), value("ProductVersion"))
        }
        deviceName = info.0.isEmpty ? "iPhone" : info.0
        iosVersion = info.1
        status = .connected
    }

    private func prepare() async throws {
        status = .working("Checking developer support…")
        let mounted: Bool = try await onQueue {
            var flag: Int32 = 0
            try Self.call("Could not check developer support") { wp_session_ddi_mounted(self.session, &flag, $0) }
            return flag != 0
        }
        if mounted {
            status = .ready
            return
        }
        let version = iosVersion.isEmpty ? UIDeviceVersion.current : iosVersion
        let cryptex = DDIService.usesCryptex(iosVersion: version)
        let folder = try await DDIService.download(cryptex: cryptex) { [weak self] message in
            self?.status = .working(message)
        }
        status = .working("Installing developer support…")
        try await onQueue {
            try Self.call("Could not install developer support") {
                wp_session_mount_ddi(self.session, folder.path, cryptex ? 1 : 0, $0)
            }
        }
        status = .ready
    }

    // MARK: Simulation

    func setLocation(_ place: Place) async throws {
        stopRoute()
        try await ensureReady()
        try await send(place.coordinate)
        simulated = place
        routePath = []
        store?.addHistory(place, kind: .teleport)
        holdKeepAlive(true)
        startRefreshing()
    }

    private func send(_ coordinate: CLLocationCoordinate2D) async throws {
        do {
            try await onQueue {
                try Self.call("Could not set the location") {
                    wp_session_set_location(self.session, coordinate.latitude, coordinate.longitude, $0)
                }
            }
        } catch {
            // The tunnel may have dropped (VPN toggled, Wi-Fi change). Reconnect once.
            status = .disconnected
            try await ensureReady()
            try await onQueue {
                try Self.call("Could not set the location") {
                    wp_session_set_location(self.session, coordinate.latitude, coordinate.longitude, $0)
                }
            }
        }
    }

    /// Re-sends the held coordinate so the channel stays alive.
    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let coordinate: CLLocationCoordinate2D?
                if let simulated = self.simulated {
                    coordinate = simulated.coordinate
                } else if let progress = self.routeProgress, progress.finished, let last = self.routePath.last {
                    coordinate = last
                } else {
                    coordinate = nil
                }
                if let coordinate { try? await self.send(coordinate) }
            }
        }
    }

    func playRoute(_ route: SavedRoute) async throws {
        guard route.points.count >= 2 else { throw DeviceError("A route needs at least two stops.") }
        guard route.speedKmh > 0 else { throw DeviceError("Choose a speed above zero.") }
        stopRoute()
        refreshTask?.cancel()
        try await ensureReady()
        let path = route.points.map(\.coordinate)
        let total = Geo.pathLengthKm(path)
        try await send(path[0])
        simulated = nil
        routePath = path
        holdKeepAlive(true)
        routeProgress = RouteProgress(routeName: route.name, travelledKm: 0, totalKm: total,
                                      remainingSeconds: route.durationSeconds, finished: false)
        let started = Date()
        routeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                let travelled = min(Date().timeIntervalSince(started) * route.speedKmh / 3600, total)
                guard let point = Geo.point(along: path, km: travelled) else { return }
                do {
                    try await self.send(point)
                } catch {
                    self.routeProgress = nil
                    self.status = .failed(error.localizedDescription)
                    self.holdKeepAlive(false)
                    return
                }
                let done = travelled >= total
                self.routeProgress = RouteProgress(routeName: route.name, travelledKm: travelled, totalKm: total,
                                                   remainingSeconds: max(0, (total - travelled) / route.speedKmh * 3600),
                                                   finished: done)
                if done {
                    // Hold the final stop, like the desktop app.
                    if let last = route.points.last {
                        self.store?.addHistory(Place(name: route.name, detail: "Route finished at \(last.name)",
                                                     latitude: last.latitude, longitude: last.longitude), kind: .route)
                    }
                    self.startRefreshing()
                    return
                }
            }
        }
    }

    private func stopRoute() {
        routeTask?.cancel()
        routeTask = nil
        routeProgress = nil
    }

    func clearLocation(silently: Bool = false) async {
        stopRoute()
        refreshTask?.cancel()
        refreshTask = nil
        let hadSession = (try? await sessionAlive()) ?? false
        if hadSession {
            do {
                try await onQueue {
                    try Self.call("Could not restore the real location") { wp_session_clear_location(self.session, $0) }
                }
            } catch {
                if !silently { status = .failed(error.localizedDescription) }
            }
        }
        simulated = nil
        routePath = []
        holdKeepAlive(false)
    }

    private func holdKeepAlive(_ on: Bool) {
        guard on != holdingKeepAlive else { return }
        holdingKeepAlive = on
        if on { KeepAlive.shared.acquire() } else { KeepAlive.shared.release() }
    }
}

enum UIDeviceVersion {
    static var current: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
