import SwiftUI
import UniformTypeIdentifiers

struct SetupView: View {
    @EnvironmentObject private var device: DeviceService
    @EnvironmentObject private var pairing: PairingService
    @EnvironmentObject private var router: Router
    @State private var importing = false
    @State private var confirmForget = false

    private static let vpnURL = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    var body: some View {
        NavigationStack {
            Form {
                statusSection

                Section {
                    StepRow(number: 1, title: "Turn on Developer Mode",
                            detail: "Settings › Privacy & Security › Developer Mode. The iPhone restarts once.")
                    StepRow(number: 2, title: "Install and turn on LocalDevVPN",
                            detail: "It lets Waypoint talk to this iPhone's developer services. It does not send your traffic anywhere.")
                    Link(destination: Self.vpnURL) { Label("Get LocalDevVPN", systemImage: "arrow.down.app") }
                } header: { Text("Before you start") }

                pairingSection

                Section {
                    Button {
                        Task {
                            do {
                                try await device.ensureReady()
                                router.toast("iPhone ready for location simulation.")
                            } catch {
                                router.toast(error.localizedDescription, error: true)
                            }
                        }
                    } label: {
                        Label("Connect and Prepare iPhone", systemImage: "bolt.horizontal.circle")
                    }
                    .disabled(!device.hasPairingFile || device.isBusy)
                } header: {
                    Text("Step 4")
                } footer: {
                    Text("The first time, Waypoint downloads Apple's developer support files (about 20 MB) and installs them. After a restart of the iPhone this runs again automatically when you set a location.")
                }

                Section("Advanced") {
                    LabeledContent("Device address") {
                        TextField("10.7.0.1", text: $device.deviceIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Pairing port") {
                        TextField("Auto", value: $device.portOverride, format: .number.grouping(.never))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                    Button("Allow background location") { KeepAlive.shared.requestPermission() }
                    Button("Re-download developer support") { DDIService.deleteDownloads(); router.toast("Downloads cleared.") }
                    Button("Disconnect") { Task { await device.disconnect() } }
                    if device.hasPairingFile {
                        Button("Forget Pairing", role: .destructive) { confirmForget = true }
                    }
                    ShareLink(item: AppPaths.logFile) { Label("Share connection log", systemImage: "doc.text") }
                }
            }
            .navigationTitle("Setup")
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.propertyList, .data, .xml],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try device.importPairingFile(from: url)
                        router.toast("Pairing file imported.")
                    } catch {
                        router.toast(error.localizedDescription, error: true)
                    }
                case .failure(let error):
                    router.toast(error.localizedDescription, error: true)
                }
            }
            .confirmationDialog("Forget this pairing?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Forget Pairing", role: .destructive) { Task { await device.forgetPairing() } }
            }
        }
    }

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title2)
                    .foregroundStyle(statusColor)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if device.isBusy { ProgressView() }
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        Section {
            switch pairing.phase {
            case .idle, .success, .failed:
                if case .failed(let message) = pairing.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                }
                if case .success(let name) = pairing.phase {
                    Label("Paired with \(name).", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.green)
                }
                Button {
                    pairing.start()
                } label: {
                    Label(device.hasPairingFile ? "Pair Again" : "Pair This iPhone", systemImage: "link")
                }
                Button { importing = true } label: {
                    Label("Import a Pairing File", systemImage: "doc.badge.plus")
                }
            case .waiting(let hostname):
                VStack(alignment: .leading, spacing: 8) {
                    HStack { ProgressView(); Text("Waiting for this iPhone…").font(.headline) }
                    Text("1. Open the Settings app (Waypoint keeps running).")
                    Text("2. Go to Privacy & Security › Developer Mode.")
                    Text("3. Tap “Pair with \(hostname)”.")
                    Text("4. Enter the code Waypoint shows here and in its notification.")
                }
                .font(.callout)
                Button("Cancel", role: .destructive) { pairing.cancel() }
            case .pin(let pin):
                VStack(spacing: 6) {
                    Text("Enter this code in Settings").font(.headline)
                    Text(pin)
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .kerning(6)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                Button("Cancel", role: .destructive) { pairing.cancel() }
            }
        } header: {
            Text("Step 3 · Pair")
        } footer: {
            Text("Pairing this iPhone directly needs iOS 27 or later. On older versions, make a pairing file on a computer once (the same kind StikDebug and SideStore use) and import it.")
        }
    }

    private var statusTitle: String {
        switch device.status {
        case .notPaired: return "Not paired"
        case .disconnected: return "Paired, not connected"
        case .working(let message): return message
        case .connected: return "Connected"
        case .ready: return device.isSimulating ? "Simulating a location" : "Ready"
        case .failed: return "Needs attention"
        }
    }

    private var statusDetail: String {
        switch device.status {
        case .failed(let message): return message
        case .notPaired: return "Follow the steps below once."
        default:
            if device.iosVersion.isEmpty { return "Set a location to connect automatically." }
            return "\(device.deviceName) · iOS \(device.iosVersion)"
        }
    }

    private var statusIcon: String {
        switch device.status {
        case .ready, .connected: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .notPaired: return "link.badge.plus"
        default: return "iphone.gen3"
        }
    }

    private var statusColor: Color {
        switch device.status {
        case .ready, .connected: return Theme.green
        case .failed, .notPaired: return .red
        default: return .secondary
        }
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Theme.coral, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
