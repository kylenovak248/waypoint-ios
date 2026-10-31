import Foundation
import UserNotifications

/// On-device pairing for iOS 27+. Waypoint advertises itself as a computer;
/// the user pairs from Settings › Privacy & Security › Developer Mode and
/// types the code Waypoint shows. No computer is involved.
@MainActor
final class PairingService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case waiting(hostname: String)
        case pin(String)
        case success(String)
        case failed(String)

        var isRunning: Bool {
            switch self {
            case .waiting, .pin: true
            default: false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private var pairing: OpaquePointer?
    private var netService: NetService?
    private var operation = UUID()

    func start() {
        guard !phase.isRunning else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let hostname = "Waypoint-" + String((0..<4).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! })
        let operation = UUID()
        self.operation = operation

        var pairing: OpaquePointer?
        var serviceID: UnsafeMutablePointer<CChar>?
        var txt: UnsafeMutablePointer<UInt8>?
        var txtLength = 0
        var port: UInt16 = 0
        var error: UnsafeMutablePointer<CChar>?
        let status = wp_pairing_start(hostname, &pairing, &serviceID, &txt, &txtLength, &port, &error)
        guard status == 0, let pairing, let serviceID, let txt else {
            phase = .failed(DeviceError.take(error, fallback: "Could not start pairing"))
            return
        }
        let service = String(cString: serviceID)
        let txtData = Data(bytes: txt, count: txtLength)
        wp_string_free(serviceID)
        wp_data_free(txt, txtLength)
        self.pairing = pairing

        guard let record = Self.txtRecord(from: txtData) else {
            self.pairing = nil
            wp_pairing_free(pairing)
            phase = .failed("Pairing information was invalid")
            return
        }
        let netService = NetService(domain: "", type: "_remotepairing-pairable-host._tcp.", name: service, port: Int32(port))
        netService.setTXTRecord(NetService.data(fromTXTRecord: record))
        netService.publish()
        self.netService = netService
        phase = .waiting(hostname: hostname)
        KeepAlive.shared.acquire()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let path = AppPaths.pairingFile.path
        let handle = UInt(bitPattern: pairing)
        DispatchQueue.global(qos: .userInitiated).async {
            var isLocal: Int32 = 0
            var name: UnsafeMutablePointer<CChar>?
            var error: UnsafeMutablePointer<CChar>?
            let status = wp_pairing_accept(OpaquePointer(bitPattern: handle), path, pairingPinCallback, context,
                                           &isLocal, &name, &error)
            // This thread owns the handle: free it only once accept has returned.
            wp_pairing_free(OpaquePointer(bitPattern: handle))
            let deviceName = name.map { String(cString: $0) } ?? "iPhone"
            wp_string_free(name)
            let message = status == 0 ? nil : DeviceError.take(error, fallback: "Pairing failed")
            DispatchQueue.main.async {
                guard self.operation == operation else { return }
                if let message {
                    self.stop(with: .failed(message))
                } else {
                    self.stop(with: .success(deviceName))
                    NotificationCenter.default.post(name: .waypointPaired, object: nil)
                }
            }
        }
    }

    func cancel() {
        operation = UUID()
        stop(with: .idle)
    }

    fileprivate func show(pin: String) {
        guard phase.isRunning else { return }
        phase = .pin(pin)
        let content = UNMutableNotificationContent()
        content.title = "Waypoint pairing code"
        content.body = "Enter \(pin) in Settings to finish pairing."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "waypoint.pin", content: content, trigger: nil))
    }

    private func stop(with newPhase: Phase) {
        netService?.stop()
        netService = nil
        if let pairing {
            // Wakes the accept thread, which then frees the handle itself.
            wp_pairing_cancel(pairing)
            self.pairing = nil
        }
        if phase.isRunning { KeepAlive.shared.release() }
        phase = newPhase
    }

    private static func txtRecord(from data: Data) -> [String: Data]? {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        return dictionary.reduce(into: [:]) { result, entry in
            switch entry.value {
            case let value as String: result[entry.key] = Data(value.utf8)
            case let value as Data: result[entry.key] = value
            case let value as NSNumber: result[entry.key] = Data(value.stringValue.utf8)
            default: break
            }
        }
    }
}

private let pairingPinCallback: wp_pin_callback = { pin, context in
    guard let pin, let context else { return }
    let value = String(cString: pin)
    let service = Unmanaged<PairingService>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { service.show(pin: value) }
}

extension Notification.Name {
    static let waypointPaired = Notification.Name("WaypointPaired")
}
