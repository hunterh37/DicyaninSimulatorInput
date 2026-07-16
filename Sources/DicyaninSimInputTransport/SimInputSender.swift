import Foundation
import Network

/// Broadcasts `SimInputPacket`s to every connected consumer over TCP.
///
/// The iPhone runner owns one of these. It listens on a fixed port (and
/// advertises a Bonjour service), accepts any number of clients (typically the
/// visionOS simulator app dialing `localhost` through the Mac, or a real
/// Vision Pro over Wi-Fi) and fans each packet out to all of them. Packets are
/// newline-framed JSON; a slow or dead client is dropped without blocking the
/// others.
///
/// Thread-safe: all connection bookkeeping happens on a private serial queue.
public final class SimInputSender: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case setup
        case ready(port: UInt16)
        case failed(String)
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dicyanin.siminput.sender")
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    /// Called on the sender's queue whenever the listener state changes.
    public var onStateChange: ((State) -> Void)?
    /// Called on the sender's queue when the connected-client count changes.
    public var onClientCountChange: ((Int) -> Void)?

    public init(port: UInt16 = SimInputWire.defaultPort,
                advertiseBonjour: Bool = true) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "SimInputSender", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "invalid port \(port)"])
        }
        listener = try NWListener(using: params, on: nwPort)
        if advertiseBonjour {
            listener.service = NWListener.Service(type: SimInputWire.bonjourServiceType)
        }
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.ready(port: self.listener.port?.rawValue ?? 0))
            case .failed(let error):
                self.onStateChange?(.failed(error.localizedDescription))
            case .setup, .waiting, .cancelled:
                break
            @unknown default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        onStateChange?(.setup)
        listener.start(queue: queue)
    }

    public func stop() {
        queue.async {
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            self.listener.cancel()
        }
    }

    /// Encode and fan a packet out to all connected clients.
    public func broadcast(_ packet: SimInputPacket) {
        guard let frame = try? SimInputWire.frame(packet) else { return }
        queue.async {
            for connection in self.connections.values {
                connection.send(content: frame, completion: .contentProcessed { _ in })
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.queue.async {
                    if self.connections.removeValue(forKey: id) != nil {
                        self.onClientCountChange?(self.connections.count)
                    }
                }
            default:
                break
            }
        }
        queue.async {
            self.connections[id] = connection
            self.onClientCountChange?(self.connections.count)
        }
        connection.start(queue: queue)
    }
}
