import Foundation
import Network

/// Connects to a `SimInputSender` and surfaces decoded packets as an
/// `AsyncStream`.
///
/// The visionOS app owns one of these. In the simulator, dial
/// `"localhost"` while the iPhone is reachable through the Mac (USB with
/// tethering or a port forward), or use the iPhone's LAN IP / Bonjour
/// discovery. Reconnects automatically if the link drops.
public final class SimInputReceiver: @unchecked Sendable {
    public enum Endpoint: Sendable {
        /// Dial a specific host and port.
        case host(String, port: UInt16)
        /// Discover the runner on the LAN via Bonjour.
        case bonjour(name: String? = nil)
    }

    private let endpoint: Endpoint
    private let queue = DispatchQueue(label: "dicyanin.siminput.receiver")
    private var connection: NWConnection?
    private var buffer = Data()
    private var continuation: AsyncStream<SimInputPacket>.Continuation?
    private var browser: NWBrowser?
    private var stopped = false

    public init(_ endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    /// Begin connecting and yield each decoded packet. The stream finishes when
    /// the receiver is cancelled, so a `for await` loop ends cleanly when the
    /// consuming task is cancelled.
    public func packets() -> AsyncStream<SimInputPacket> {
        AsyncStream { continuation in
            self.queue.async {
                self.continuation = continuation
                self.stopped = false
                self.openConnection()
            }
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }
    }

    public func cancel() {
        queue.async {
            self.stopped = true
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
            self.continuation?.finish()
            self.continuation = nil
        }
    }

    // MARK: - Connection lifecycle

    private func openConnection() {
        guard !stopped else { return }
        switch endpoint {
        case let .host(host, port):
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
            connect(to: NWConnection(to: endpoint, using: .tcp))
        case let .bonjour(name):
            browseAndConnect(name: name)
        }
    }

    private func browseAndConnect(name: String?) {
        let descriptor = NWBrowser.Descriptor.bonjour(
            type: SimInputWire.bonjourServiceType, domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let match = results.first { result in
                guard let name else { return true }
                if case let .service(serviceName, _, _, _) = result.endpoint {
                    return serviceName == name
                }
                return false
            }
            guard let match else { return }
            browser.cancel()
            self.browser = nil
            self.connect(to: NWConnection(to: match.endpoint, using: .tcp))
        }
        browser.start(queue: queue)
    }

    private func connect(to connection: NWConnection) {
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.buffer.removeAll(keepingCapacity: true)
                self.receive()
            case .failed, .cancelled:
                self.scheduleReconnect()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func scheduleReconnect() {
        guard !stopped else { return }
        connection = nil
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.openConnection()
        }
    }

    // MARK: - Read + frame splitting

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainFrames()
            }
            if isComplete || error != nil {
                self.scheduleReconnect()
            } else {
                self.receive()
            }
        }
    }

    private func drainFrames() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !frame.isEmpty,
                  let packet = try? SimInputWire.decode(Data(frame)) else { continue }
            continuation?.yield(packet)
        }
    }
}
