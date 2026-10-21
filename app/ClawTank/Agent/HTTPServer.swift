// Minimal HTTP/1.1 server for the Agent API: loopback only (127.0.0.1), one request per
// connection (Connection: close), Content-Length bodies up to 1 MiB. Enough for a local JSON
// API; deliberately not a general web server.

import Foundation
import Network

struct HTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]  // lower-cased names
    let body: Data

    enum Parse: Equatable {
        case incomplete
        case invalid(String)
        case complete(HTTPRequest)
    }

    static let maxBody = 1 << 20
    static let maxHeader = 16 << 10

    /// Parses a request from the bytes received so far.
    static func parse(_ data: Data) -> Parse {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeader ? .invalid("header too large") : .incomplete
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid("not UTF-8") }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header") }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .invalid("chunked bodies are not supported") }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard (0...maxBody).contains(length) else { return .invalid("bad content length") }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        let body = data[bodyStart..<(bodyStart + length)]

        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(HTTPRequest(method: String(parts[0]), path: components?.path ?? target, query: query,
                                     headers: headers, body: Data(body)))
    }
}

struct HTTPResponse: Sendable {
    var status: Int
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var body = Data()

    static func json(_ status: Int, _ object: Any) -> HTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, body: body)
    }

    static func error(_ status: Int, _ message: String) -> HTTPResponse { json(status, ["error": message]) }

    var serialized: Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 409: "Conflict", 413: "Payload Too Large", 429: "Too Many Requests",
                      500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
        head += "Connection: close\r\nCache-Control: no-store\r\n"
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

final class HTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "dev.clawtank.agent-http")
    private let handler: Handler

    /// Binds 127.0.0.1:`port` only; other machines can never reach it.
    init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
        self.handler = handler
    }

    func start(onState: @escaping @Sendable (NWListener.State) -> Void) {
        listener.stateUpdateHandler = onState
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
    }

    func stop() { listener.cancel() }

    var port: UInt16? { listener.port?.rawValue }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Drop idle or slow connections.
        queue.asyncAfter(deadline: .now() + 30) { connection.cancel() }
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }
            switch HTTPRequest.parse(buffer) {
            case .complete(let request):
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    connection.send(content: response.serialized, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
            case .invalid(let reason):
                connection.send(content: HTTPResponse.error(400, reason).serialized,
                                completion: .contentProcessed { _ in connection.cancel() })
            case .incomplete:
                if done || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
            }
        }
    }
}
