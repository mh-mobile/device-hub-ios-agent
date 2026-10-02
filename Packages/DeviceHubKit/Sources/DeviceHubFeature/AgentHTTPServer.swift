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
/// ponytail: no auth, one request per connection. Reach it only over a network you
/// trust (e.g. a tailnet); add a token before using it anywhere else.
public final class AgentHTTPServer: @unchecked Sendable {
    public static let shared = AgentHTTPServer()
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "agent.http")

    public func start(port: UInt16 = 8765) {
        guard listener == nil, let nwPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: nwPort) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Request(buffer) {
                Task { await self.respond(to: request, on: connection) }
            } else if done || error != nil || buffer.count > 1_000_000 {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Request, on connection: NWConnection) async {
        let bridge = AgentBridge.shared
        let body = request.json
        func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
        do {
            switch (request.method, request.path) {
            case ("GET", "/screen"):
                let size = try bridge.screenSize()
                send(connection, json: ["width": size.width, "height": size.height])
            case ("GET", "/screenshot"):
                send(connection, status: "200 OK", type: "image/png", body: try bridge.screenshotPNG())
            case ("POST", "/tap"):
                guard let x = number("x"), let y = number("y") else { throw AgentBridgeError("tap needs x and y") }
                try await bridge.tap(x: x, y: y)
                send(connection, json: ["ok": true])
            case ("POST", "/drag"):
                guard let x1 = number("x1"), let y1 = number("y1"), let x2 = number("x2"), let y2 = number("y2")
                else { throw AgentBridgeError("drag needs x1, y1, x2, y2") }
                try await bridge.drag(from: (x1, y1), to: (x2, y2), duration: number("duration") ?? 0.3)
                send(connection, json: ["ok": true])
            case ("POST", "/type"):
                guard let text = body["text"] as? String else { throw AgentBridgeError("type needs text") }
                try await bridge.type(text)
                send(connection, json: ["ok": true])
            case ("POST", "/button"):
                guard let name = body["name"] as? String else { throw AgentBridgeError("button needs name") }
                try await bridge.press(name)
                send(connection, json: ["ok": true])
            default:
                send(connection, status: "404 Not Found", json: ["error": "no route \(request.method) \(request.path)"])
            }
        } catch {
            send(connection, status: "409 Conflict", json: ["error": String(describing: error)])
        }
    }

    private func send(_ connection: NWConnection, status: String = "200 OK", json: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        send(connection, status: status, type: "application/json", body: body)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data) {
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// One complete request: the head and, when Content-Length says so, its body.
private struct Request {
    let method: String
    let path: String
    let json: [String: Any]

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        let body = data[end.upperBound...]
        guard body.count >= length else { return nil }
        method = String(first[0])
        path = String(first[1].split(separator: "?").first ?? "")
        json = length > 0 ? ((try? JSONSerialization.jsonObject(with: body.prefix(length))) as? [String: Any] ?? [:]) : [:]
    }
}
