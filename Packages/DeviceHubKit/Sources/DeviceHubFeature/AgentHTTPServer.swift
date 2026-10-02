import Foundation
import Network

/// A small HTTP/1.1 server an agent on another machine drives the shown device with.
///
///     GET  /screen                      {"width":…, "height":…} in target pixels
///     GET  /screenshot                  PNG of the latest frame
///     POST /tap      {"x":…, "y":…}
///     POST /drag     {"x1":…, "y1":…, "x2":…, "y2":…, "duration":0.3}
///     POST /type     {"text":"…"}
///     POST /button   {"name":"home|lock|mute|siri|volumeUp|volumeDown"}
///
/// Every request is checked by `AgentAccessPolicy` (loopback or tailnet source
/// plus a bearer token); the server does not start without a token. One
/// request per connection.
public final class AgentHTTPServer: @unchecked Sendable {
    public static let shared = AgentHTTPServer()

    /// A connection that has not delivered a full request by then is closed.
    static let requestTimeout: DispatchTimeInterval = .seconds(10)
    static let restartDelay: DispatchTimeInterval = .seconds(2)

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agent.http")

    /// Starts listening when `policy` is non-nil; a failed listener restarts itself.
    public func start(policy: AgentAccessPolicy?, port: UInt16 = 8765) {
        guard let policy else {
            return
        }
        queue.async { self.listen(policy: policy, port: port) }
    }

    private func listen(policy: AgentAccessPolicy, port: UInt16) {
        guard listener == nil,
              let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort)
        else {
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection, policy: policy)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, case .failed = state else {
                return
            }
            listener?.cancel()
            self.listener = nil
            queue.asyncAfter(deadline: .now() + Self.restartDelay) {
                self.listen(policy: policy, port: port)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection, policy: AgentAccessPolicy) {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            connection.cancel()
        }
        receive(connection, buffer: Data(), policy: policy)
    }

    private func receive(
        _ connection: NWConnection,
        buffer: Data,
        policy: AgentAccessPolicy
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { [weak self] data, _, done, error in
            guard let self else {
                return
            }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            switch AgentHTTPRequest.parse(buffer) {
            case let .complete(request):
                let decision = policy.decide(
                    sourceAddress: Self.sourceAddress(of: connection),
                    authorization: request.header("authorization")
                )
                switch decision {
                case .allowed:
                    Task { await self.respond(to: request, on: connection) }
                case .forbiddenSource:
                    send(connection, status: "403 Forbidden", json: ["error": "forbidden source"])
                case .unauthorized:
                    send(connection, status: "401 Unauthorized", json: ["error": "missing or wrong token"])
                }
            case .malformed:
                send(connection, status: "400 Bad Request", json: ["error": "malformed request"])
            case .incomplete:
                if done || error != nil {
                    connection.cancel()
                } else {
                    receive(connection, buffer: buffer, policy: policy)
                }
            }
        }
    }

    private static func sourceAddress(of connection: NWConnection) -> [UInt8] {
        guard case let .hostPort(host, _) = connection.endpoint else {
            return []
        }
        switch host {
        case let .ipv4(address):
            return Array(address.rawValue)
        case let .ipv6(address):
            return Array(address.rawValue)
        default:
            return []
        }
    }

    private func respond(to request: AgentHTTPRequest, on connection: NWConnection) async {
        let bridge = AgentBridge.shared
        do {
            switch (request.method, request.path) {
            case ("GET", "/screen"):
                let size = try bridge.screenSize()
                send(connection, json: ["width": size.width, "height": size.height])
            case ("GET", "/screenshot"):
                let png = try bridge.screenshotPNG()
                send(connection, status: "200 OK", type: "image/png", body: png)
            case ("POST", "/tap"):
                guard let x = request.number("x"), let y = request.number("y") else {
                    throw AgentBridgeError("tap needs finite x and y")
                }
                try await bridge.tap(x: x, y: y)
                send(connection, json: ["ok": true])
            case ("POST", "/drag"):
                guard let x1 = request.number("x1"), let y1 = request.number("y1"),
                      let x2 = request.number("x2"), let y2 = request.number("y2")
                else {
                    throw AgentBridgeError("drag needs finite x1, y1, x2, y2")
                }
                try await bridge.drag(
                    from: (x1, y1),
                    to: (x2, y2),
                    duration: request.number("duration") ?? 0.3
                )
                send(connection, json: ["ok": true])
            case ("POST", "/type"):
                guard let text = request.string("text") else {
                    throw AgentBridgeError("type needs text")
                }
                try await bridge.type(text)
                send(connection, json: ["ok": true])
            case ("POST", "/button"):
                guard let name = request.string("name") else {
                    throw AgentBridgeError("button needs name")
                }
                try await bridge.press(name)
                send(connection, json: ["ok": true])
            default:
                send(
                    connection,
                    status: "404 Not Found",
                    json: ["error": "no route \(request.method) \(request.path)"]
                )
            }
        } catch let error as AgentBridgeError {
            send(connection, status: "400 Bad Request", json: ["error": error.description])
        } catch let error as AgentBridge.Failure {
            send(connection, status: "409 Conflict", json: ["error": error.description])
        } catch {
            send(
                connection,
                status: "500 Internal Server Error",
                json: ["error": String(describing: error)]
            )
        }
    }

    private func send(_ connection: NWConnection, status: String = "200 OK", json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(connection, status: status, type: "application/json", body: body)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data) {
        var out = Data(
            ("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n"
                + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n").utf8
        )
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One complete request: the head and, when Content-Length says so, its body.
struct AgentHTTPRequest: Equatable {
    static let maximumHeadBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    enum ParseResult: Equatable {
        case complete(AgentHTTPRequest)
        case incomplete
        case malformed
    }

    let method: String
    let path: String
    private let headers: [String: String]
    private let body: Data

    static func parse(_ data: Data) -> ParseResult {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeadBytes ? .malformed : .incomplete
        }
        guard end.lowerBound - data.startIndex <= maximumHeadBytes,
              let head = String(data: data[..<end.lowerBound], encoding: .utf8)
        else {
            return .malformed
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .malformed
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else {
                return .malformed
            }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), (0 ... maximumBodyBytes).contains(value) else {
                return .malformed
            }
            length = value
        }
        let body = data[end.upperBound...]
        guard body.count >= length else {
            return .incomplete
        }
        return .complete(AgentHTTPRequest(
            method: String(requestLine[0]),
            path: String(requestLine[1].split(separator: "?").first ?? ""),
            headers: headers,
            body: Data(body.prefix(length))
        ))
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }

    /// A finite JSON number field, or `nil`.
    func number(_ key: String) -> Double? {
        guard let value = (json[key] as? NSNumber)?.doubleValue, value.isFinite else {
            return nil
        }
        return value
    }

    func string(_ key: String) -> String? {
        json[key] as? String
    }

    private var json: [String: Any] {
        guard !body.isEmpty else {
            return [:]
        }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    }
}
