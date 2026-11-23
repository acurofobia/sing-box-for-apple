import Foundation
import Network

final class SettingsVLESSFixture: @unchecked Sendable {
    enum Stage: String {
        case a, b, revoked

        fileprivate var title: String {
            switch self {
            case .a: return "Profile A"
            case .b: return "Profile B"
            case .revoked: return "VLESS revoked"
            }
        }
    }

    private enum Request {
        case incomplete, reject, reply(Data)
    }

    private static let httpPort: NWEndpoint.Port = 18971
    private static let host = "127.0.0.1"
    private let queue = DispatchQueue(label: "SettingsVLESSFixture")
    private let lock = NSLock()
    private let credentialA = UUID()
    private let credentialB = UUID()
    private var currentStage = Stage.a
    private var observedProfiles = Set<Stage>()
    private var listeners: [NWListener] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    let source = URL(string: "http://\(SettingsVLESSFixture.host):\(SettingsVLESSFixture.httpPort.rawValue)/subscription")!

    var stage: Stage {
        get { lock.withLock { currentStage } }
        set { lock.withLock { currentStage = newValue } }
    }

    func sawProfile(_ profile: Stage) -> Bool {
        lock.withLock { observedProfiles.contains(profile) }
    }

    func resetObservations() {
        lock.withLock { observedProfiles.removeAll() }
    }

    func start() async throws {
        do {
            let listenerA = try await listen { [weak self, credentialA] data in
                self?.probe(data, profile: .a, credential: credentialA) ?? .reject
            }
            let listenerB = try await listen { [weak self, credentialB] data in
                self?.probe(data, profile: .b, credential: credentialB) ?? .reject
            }
            guard let portA = listenerA.port, let portB = listenerB.port else {
                throw CocoaError(.fileReadUnknown)
            }
            _ = try await listen(port: Self.httpPort) { [weak self] data in
                self?.http(data, portA: portA, portB: portB) ?? .reject
            }
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        let (listeners, connections) = lock.withLock {
            let resources = (listeners, Array(connections.values))
            self.listeners.removeAll()
            self.connections.removeAll()
            return resources
        }
        listeners.forEach { $0.cancel() }
        connections.forEach { $0.cancel() }
    }

    deinit {
        stop()
    }

    private func listen(port: NWEndpoint.Port = .any, request: @escaping @Sendable (Data) -> Request) async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        lock.withLock { listeners.append(listener) }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else {
                connection.cancel()
                return
            }
            self.accept(connection, listener: listener, request: request)
        }

        let updates = AsyncThrowingStream<Void, Error> { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    continuation.yield()
                    continuation.finish()
                case let .failed(error), let .waiting(error):
                    continuation.finish(throwing: error)
                case .cancelled:
                    continuation.finish(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.stateUpdateHandler = nil }
        for try await _ in updates {
            try Task.checkCancellation()
            return listener
        }
        throw CancellationError()
    }

    private func accept(_ connection: NWConnection, listener: NWListener, request: @escaping @Sendable (Data) -> Request) {
        let id = ObjectIdentifier(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                _ = self?.lock.withLock { self?.connections.removeValue(forKey: id) }
            default:
                break
            }
        }
        let accepted = lock.withLock {
            guard listeners.contains(where: { $0 === listener }) else { return false }
            connections[id] = connection
            connection.start(queue: queue)
            return true
        }
        guard accepted else {
            connection.cancel()
            return
        }
        queue.asyncAfter(deadline: .now() + 5) { [weak connection] in connection?.cancel() }
        receive(connection, buffered: Data(), request: request)
    }

    private func receive(_ connection: NWConnection, buffered: Data, request: @escaping @Sendable (Data) -> Request) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            var bytes = buffered
            if let data { bytes.append(data) }
            switch request(bytes) {
            case let .reply(reply):
                connection.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .incomplete where !complete && error == nil && bytes.count < 8192:
                self.receive(connection, buffered: bytes, request: request)
            default:
                connection.cancel()
            }
        }
    }

    private func http(_ data: Data, portA: NWEndpoint.Port, portB: NWEndpoint.Port) -> Request {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let header = String(data: data[..<headerEnd.lowerBound], encoding: .utf8),
              let requestLine = header.components(separatedBy: "\r\n").first else { return .reject }
        let words = requestLine.split(separator: " ")
        guard words.count == 3, words[0] == "GET" else { return .reject }
        if words[1] == "/subscription" {
            // Encode the stage into both URLs so one transaction reads a consistent snapshot.
            let root = source.deletingLastPathComponent().appendingPathComponent(stage.rawValue)
            return response([
                "sing_box_url": root.appendingPathComponent("vless").absoluteString,
                "ui_url": root.appendingPathComponent("ui").absoluteString,
            ])
        }

        let path = words[1].split(separator: "/")
        guard path.count == 2, let stage = Stage(rawValue: String(path[0])) else { return response([:], status: "404 Not Found") }
        switch path[1] {
        case "vless":
            switch stage {
            case .a: return node(port: portA, credential: credentialA)
            case .b: return node(port: portB, credential: credentialB)
            case .revoked:
                return response(["schemaVersion": 1, "kind": "vless-failover", "state": "unavailable",
                                 "reason": "not_allowed", "outbounds": []])
            }
        case "ui":
            let card: [String: Any] = ["id": "block01", "type": "card", "title": stage.title, "buttons": []]
            let option: [String: Any] = ["id": "option01", "title": "VLESS", "text": "VLESS fixture",
                                         "state": stage == .revoked ? "unavailable" : "available", "buttons": []]
            let modes: [String: Any] = ["id": "block04", "type": "selectionList", "items": [option]]
            let edit: [String: Any] = ["id": "item01", "title": "Edit fixture URL",
                                       "action": ["type": "openScreen", "targetId": "screen01"]]
            let menu: [String: Any] = ["id": "block05", "type": "menu", "items": [edit]]
            return response(["schemaVersion": 1, "blocks": [card, modes, menu], "pages": []])
        default:
            return response([:], status: "404 Not Found")
        }
    }

    private func node(port: NWEndpoint.Port, credential: UUID) -> Request {
        response(["type": "vless", "tag": "R3-N1", "server": Self.host,
                  "server_port": Int(port.rawValue), "uuid": credential.uuidString])
    }

    private func response(_ value: [String: Any], status: String = "200 OK") -> Request {
        guard let body = try? JSONSerialization.data(withJSONObject: value) else { return .reject }
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(body)
        return .reply(response)
    }

    private func probe(_ data: Data, profile: Stage, credential: UUID) -> Request {
        // Version, UUID, empty addons, TCP command, destination port and address type.
        guard data.count >= 22 else { return .incomplete }
        guard data[0] == 0, data[17] == 0, data[18] == 1,
              data[19] != 0 || data[20] != 0,
              withUnsafeBytes(of: credential.uuid, { data[1 ..< 17].elementsEqual($0) })
        else { return .reject }
        let addressLength: Int
        switch data[21] {
        case 1: addressLength = 4
        case 2:
            guard data.count >= 23 else { return .incomplete }
            guard data[22] != 0 else { return .reject }
            addressLength = 1 + Int(data[22])
        case 3: addressLength = 16
        default: return .reject
        }
        guard data.count >= 22 + addressLength else { return .incomplete }
        _ = lock.withLock { observedProfiles.insert(profile) }
        // Complete only the VLESS handshake. No destination is dialed and no payload is relayed.
        return .reply(Data([0, 0]))
    }
}
