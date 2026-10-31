import Foundation
import Network

/// Finds the port of the iPhone's own Remote Pairing service
/// (`_remotepairing._tcp`), preferring the loopback copy. Falls back to 49152.
final class PortResolver {
    static let fallbackPort: UInt16 = 49152

    private let queue = DispatchQueue(label: "waypoint.port-resolver")
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var chosenIsLoopback = false
    private var finished = false
    private var continuation: CheckedContinuation<UInt16?, Never>?

    static func resolve(timeout: TimeInterval = 5) async -> UInt16 {
        await PortResolver().run(timeout: timeout) ?? fallbackPort
    }

    private func run(timeout: TimeInterval) async -> UInt16? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.start()
                self.queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
            }
        }
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_remotepairing._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.finished else { return }
            let candidates = results.compactMap { result -> (NWEndpoint, Bool)? in
                guard case .service = result.endpoint else { return nil }
                return (result.endpoint, result.interfaces.contains { $0.name.hasPrefix("lo") })
            }
            guard let pick = candidates.first(where: { $0.1 }) ?? candidates.first else { return }
            // Only switch when we upgrade to the loopback copy.
            if self.connection != nil && (self.chosenIsLoopback || !pick.1) { return }
            self.chosenIsLoopback = pick.1
            self.connection?.cancel()
            let connection = NWConnection(to: pick.0, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready, .waiting, .preparing:
                    if case .hostPort(_, let port) = connection.currentPath?.remoteEndpoint, port.rawValue != 0 {
                        self.finish(port.rawValue)
                    }
                case .failed:
                    self.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.finish(nil) }
        }
        browser.start(queue: queue)
    }

    private func finish(_ port: UInt16?) {
        guard !finished else { return }
        finished = true
        browser?.cancel()
        connection?.cancel()
        continuation?.resume(returning: port)
        continuation = nil
    }
}
