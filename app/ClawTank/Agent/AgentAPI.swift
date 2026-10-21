// Agent API router: authentication, the "human always wins" rule, audit logging and dispatch to
// the AgentHost. Transport-independent (HTTPServer feeds it), so it's tested directly.
//
//   GET    /v1/health                      no auth: {"ok": true, "version": …}
//   GET    /v1/displays                    displays (points, scale, main, virtual)
//   GET    /v1/screenshot?display=&max_width=&format=png|jpeg
//   GET    /v1/state                       cursor, frontmost app + window title, screen locked
//   POST   /v1/input                       {"actions": [{"type": "click", "x": 10, "y": 20}, …]}
//   POST   /v1/apps/open                   {"name": "TextEdit"} (name or bundle id)
//   POST   /v1/virtual-displays            {"width": 1920, "height": 1080, "hidpi": false}
//   DELETE /v1/virtual-displays/{id}
//
// Security: loopback only (HTTPServer), a per-agent bearer token on every call except health,
// browser requests refused (any Origin header, or a Host that isn't loopback: DNS rebinding),
// repeated bad tokens throttled, and every request audited.

import Foundation

/// When a person last controlled the Mac through an RDP session. Agents yield to them.
final class HumanActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var last: TimeInterval = -.infinity
    private let clock: @Sendable () -> TimeInterval

    init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    func touch() { lock.withLock { last = clock() } }
    var secondsSinceInput: TimeInterval { lock.withLock { clock() - last } }
}

/// What the router reports to the app (indicator, audit).
struct AgentEvent: Sendable {
    let agent: String
    let action: String
    let allowed: Bool
    let detail: String?
}

final class AgentAPI: @unchecked Sendable {
    static let humanGraceSeconds: TimeInterval = 3

    private let host: AgentHost
    private let tokens: AgentTokenStore
    private let human: HumanActivity
    private let port: () -> Int
    private let onEvent: @Sendable (AgentEvent) -> Void
    private let lock = NSLock()
    private var failures: [TimeInterval] = []
    private let clock: @Sendable () -> TimeInterval

    init(host: AgentHost, tokens: AgentTokenStore, human: HumanActivity, port: @escaping () -> Int,
         clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         onEvent: @escaping @Sendable (AgentEvent) -> Void) {
        self.host = host
        self.tokens = tokens
        self.human = human
        self.port = port
        self.clock = clock
        self.onEvent = onEvent
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.headers["origin"] != nil { return .error(403, "browser requests are not allowed") }
        let validHosts = ["127.0.0.1:\(port())", "localhost:\(port())", "127.0.0.1", "localhost"]
        guard let hostHeader = request.headers["host"], validHosts.contains(hostHeader.lowercased()) else {
            return .error(403, "Host must be 127.0.0.1")
        }
        if request.method == "GET", request.path == "/v1/health" {
            return .json(200, ["ok": true, "version": Bundle.main.shortVersion])
        }
        guard let agent = authenticate(request) else {
            return throttled ? .error(429, "too many failed attempts; try again in a minute")
                : .error(401, "missing or invalid token (Authorization: Bearer ct_…)")
        }
        return await route(request, agent: agent.name)
    }

    // MARK: Auth

    private var throttled: Bool {
        lock.withLock {
            let now = clock()
            failures.removeAll { now - $0 > 60 }
            return failures.count >= 10
        }
    }

    private func authenticate(_ request: HTTPRequest) -> AgentToken? {
        guard !throttled else { return nil }
        let header = request.headers["authorization"] ?? ""
        if header.hasPrefix("Bearer "), let token = tokens.verify(String(header.dropFirst(7))) { return token }
        lock.withLock { failures.append(clock()) }
        onEvent(AgentEvent(agent: "(unknown)", action: "\(request.method) \(request.path)", allowed: false,
                           detail: header.isEmpty ? "no token" : "invalid token"))
        return nil
    }

    // MARK: Routing

    private typealias Route = @Sendable (AgentAPI, HTTPRequest, String) async throws -> HTTPResponse

    private static let routes: [String: Route] = [
        "GET /v1/displays": { api, _, agent in await api.displays(agent: agent) },
        "GET /v1/screenshot": { api, request, agent in try await api.screenshot(request, agent: agent) },
        "GET /v1/state": { api, _, agent in await api.state(agent: agent) },
        "POST /v1/input": { api, request, agent in try await api.input(request, agent: agent) },
        "POST /v1/apps/open": { api, request, agent in try await api.openApp(request, agent: agent) },
        "POST /v1/virtual-displays": { api, request, agent in try await api.createDisplay(request, agent: agent) },
        "DELETE /v1/virtual-displays/{id}": { api, request, agent in
            await api.removeDisplay(request.path.split(separator: "/").last.map(String.init) ?? "", agent: agent)
        }
    ]

    private static let knownPaths = Set(routes.keys.compactMap { $0.split(separator: " ").last.map(String.init) })

    private func route(_ request: HTTPRequest, agent: String) async -> HTTPResponse {
        var path = request.path
        if path.hasPrefix("/v1/virtual-displays/") { path = "/v1/virtual-displays/{id}" }
        guard let route = Self.routes["\(request.method) \(path)"] else {
            return Self.knownPaths.contains(path) || path == "/v1/health"
                ? .error(405, "method not allowed") : .error(404, "unknown endpoint; see docs/agent-api.md")
        }
        do {
            return try await route(self, request, agent)
        } catch let error as AgentHostError {
            record(agent, "\(request.method) \(request.path)", allowed: false, detail: error.description)
            switch error {
            case .noSuchDisplay, .notFound: return .error(404, error.description)
            case .notPermitted: return .error(503, error.description)
            case .failed: return .error(500, error.description)
            }
        } catch {
            record(agent, "\(request.method) \(request.path)", allowed: false, detail: "\(error)")
            return .error(500, "\(error)")
        }
    }

    private func displays(agent: String) async -> HTTPResponse {
        let displays = await host.displays()
        record(agent, "list displays")
        return .json(200, ["displays": displays.map(\.json)])
    }

    private func state(agent: String) async -> HTTPResponse {
        let state = await host.state()
        record(agent, "read state")
        return .json(200, state.json)
    }

    private func input(_ request: HTTPRequest, agent: String) async throws -> HTTPResponse {
        let actions: [AgentAction]
        do { actions = try AgentAction.parseList(request.body) } catch let error as AgentAction.ParseError {
            return .error(400, error.description)
        }
        if let refusal = yieldToHuman(agent, actions.map(\.auditDescription).joined(separator: "; ")) {
            return refusal
        }
        for action in actions {
            try await host.perform(action)
            record(agent, action.auditDescription)
        }
        return .json(200, ["ok": true, "performed": actions.count])
    }

    private func openApp(_ request: HTTPRequest, agent: String) async throws -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
        guard let name = (body?["name"] ?? body?["bundle_id"]) as? String else {
            return .error(400, "body must be {\"name\": \"TextEdit\"}")
        }
        if let refusal = yieldToHuman(agent, "open app \(name)") { return refusal }
        let opened = try await host.openApp(name)
        record(agent, "open app \(opened)")
        return .json(200, ["ok": true, "app": opened])
    }

    private func createDisplay(_ request: HTTPRequest, agent: String) async throws -> HTTPResponse {
        let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        let width = (body["width"] as? NSNumber)?.intValue ?? 1920
        let height = (body["height"] as? NSNumber)?.intValue ?? 1080
        let hiDPI = body["hidpi"] as? Bool ?? false
        let id = try await host.createVirtualDisplay(width: width, height: height, hiDPI: hiDPI)
        record(agent, "create virtual display \(id) (\(width)×\(height)\(hiDPI ? " HiDPI" : ""))")
        return .json(200, ["id": id])
    }

    private func removeDisplay(_ idText: String, agent: String) async -> HTTPResponse {
        guard let id = UInt32(idText) else { return .error(400, "bad display id") }
        guard await host.removeVirtualDisplay(id) else {
            return .error(404, "display \(id) wasn't created by the Agent API")
        }
        record(agent, "remove virtual display \(id)")
        return .json(200, ["ok": true])
    }

    private func screenshot(_ request: HTTPRequest, agent: String) async throws -> HTTPResponse {
        let display = request.query["display"].flatMap { UInt32($0) }
        let maxWidth = request.query["max_width"].flatMap { Int($0) }
        let jpeg = request.query["format"] == "jpeg"
        let shot = try await host.screenshot(display: display, maxWidth: maxWidth, jpeg: jpeg)
        record(agent, "screenshot of display \(shot.display) (\(shot.width)×\(shot.height))")
        return HTTPResponse(status: 200, contentType: shot.mimeType, headers: [
            "X-ClawTank-Display": "\(shot.display)", "X-ClawTank-Width": "\(shot.width)",
            "X-ClawTank-Height": "\(shot.height)",
            "X-ClawTank-Points-Per-Pixel": String(format: "%.4f", shot.pointsPerPixel)
        ], body: shot.data)
    }

    /// Refuses control actions while a person is using the Mac over RDP.
    private func yieldToHuman(_ agent: String, _ description: String) -> HTTPResponse? {
        let idle = human.secondsSinceInput
        guard idle < Self.humanGraceSeconds else { return nil }
        record(agent, description, allowed: false, detail: "a person is using this Mac")
        let wait = Int((Self.humanGraceSeconds - idle).rounded(.up))
        return .error(409, "a person is using this Mac; retry in \(wait) s")
    }

    private func record(_ agent: String, _ action: String, allowed: Bool = true, detail: String? = nil) {
        onEvent(AgentEvent(agent: agent, action: action, allowed: allowed, detail: detail))
    }
}
