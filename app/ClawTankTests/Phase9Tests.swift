import XCTest
@testable import ClawTank

final class HTTPRequestTests: XCTestCase {
    func testParsesRequestIncrementally() {
        let raw = "POST /v1/input?x=1&y=two HTTP/1.1\r\nHost: 127.0.0.1:3390\r\nContent-Length: 4\r\n\r\nbody"
        XCTAssertEqual(HTTPRequest.parse(Data(raw.utf8).prefix(20)), .incomplete)
        XCTAssertEqual(HTTPRequest.parse(Data(raw.utf8).dropLast(2)), .incomplete, "body not complete yet")
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/input")
        XCTAssertEqual(request.query, ["x": "1", "y": "two"])
        XCTAssertEqual(request.headers["host"], "127.0.0.1:3390")
        XCTAssertEqual(request.body, Data("body".utf8))
    }

    func testRejectsBadRequests() {
        XCTAssertEqual(HTTPRequest.parse(Data("GARBAGE\r\n\r\n".utf8)), .invalid("bad request line"))
        XCTAssertEqual(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)),
                       .invalid("bad content length"))
        XCTAssertEqual(HTTPRequest.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)),
                       .invalid("chunked bodies are not supported"))
        XCTAssertEqual(HTTPRequest.parse(Data(repeating: 65, count: HTTPRequest.maxHeader + 1)),
                       .invalid("header too large"))
    }

    func testServesOverLoopback() async throws {
        let server = try HTTPServer(port: 0) { request in .json(200, ["path": request.path]) }
        let ready = expectation(description: "listening")
        server.start { if case .ready = $0 { ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 5)
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/v1/x")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? [String: String], ["path": "/v1/x"])
    }
}

final class AgentActionTests: XCTestCase {
    private func parse(_ json: String) throws -> [AgentAction] { try AgentAction.parseList(Data(json.utf8)) }

    func testParsesActions() throws {
        let actions = try parse("""
        {"actions": [{"type": "click", "x": 10, "y": 20.5, "count": 2, "display": 5},
                     {"type": "type", "text": "héllo"}, {"type": "key", "key": "cmd+shift+t"},
                     {"type": "scroll", "dy": 3}, {"type": "drag", "from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4}]}
        """)
        XCTAssertEqual(actions[0], .click(display: 5, x: 10, y: 20.5, button: .left, count: 2))
        XCTAssertEqual(actions[1], .type("héllo"))
        XCTAssertEqual(actions[2], .key(KeyCombo("cmd+shift+t")!))
        XCTAssertEqual(actions[3], .scroll(display: nil, x: nil, y: nil, dx: 0, dy: 3))
        XCTAssertEqual(try parse(#"{"type": "move", "x": 1, "y": 2}"#), [.move(display: nil, x: 1, y: 2)],
                       "a single action object")
        XCTAssertEqual(actions[1].auditDescription, "type 5 characters", "typed text is not logged")
        XCTAssertEqual(actions[0].auditDescription, "2× left click at 10,20 on display 5")
    }

    func testRejectsInvalidActions() {
        for body in [#"[]"#, #"{"actions": []}"#, #"{"type": "click", "x": 1}"#, #"{"type": "explode"}"#,
                     #"{"type": "click", "x": 1, "y": 2, "button": "fourth"}"#, #"{"type": "key", "key": "cmd+nope"}"#,
                     #"{"type": "scroll", "dy": 1000}"#, #"{"type": "click", "x": 1, "y": 2, "count": 9}"#] {
            XCTAssertThrowsError(try parse(body), body)
        }
    }

    func testKeyCombos() throws {
        let combo = try XCTUnwrap(KeyCombo("Cmd+Space"))
        XCTAssertEqual(combo.keyCode, 49)
        XCTAssertEqual(combo.flags, .maskCommand)
        XCTAssertEqual(KeyCombo("ctrl+alt+shift+f5")?.flags, [.maskControl, .maskAlternate, .maskShift])
        XCTAssertEqual(KeyCombo("return")?.keyCode, 36)
        XCTAssertEqual(KeyCombo("a")?.keyCode, 0)
        XCTAssertEqual(KeyCombo("cmd++")?.keyCode, KeyCombo("=")?.keyCode)
        XCTAssertNil(KeyCombo("hyper+a"))
        XCTAssertNil(KeyCombo(""))
    }
}

final class AgentTokenStoreTests: XCTestCase {
    func testCreateVerifyRevokeAndPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AgentTokenStore(url: url)
        let (token, secret) = store.create(name: "Claude")
        XCTAssertTrue(secret.hasPrefix("ct_"))
        XCTAssertGreaterThan(secret.count, 40)
        XCTAssertEqual(store.verify(secret)?.id, token.id)
        XCTAssertNil(store.verify(secret + "x"))
        XCTAssertNil(store.verify(""))
        let file = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(file.contains(secret), "only the hash is stored")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertEqual(AgentTokenStore(url: url).verify(secret)?.name, "Claude", "reloads from disk")
        store.revoke(id: token.id)
        XCTAssertNil(store.verify(secret))
        XCTAssertNil(AgentTokenStore(url: url).verify(secret))
    }
}

/// Records what the router asked the Mac to do.
final class FakeAgentHost: AgentHost, @unchecked Sendable {
    var performed: [AgentAction] = []
    var opened: [String] = []

    func displays() async -> [DisplayInfo] {
        [DisplayInfo(id: 1, widthPoints: 1512, heightPoints: 982, scale: 2, isMain: true, isVirtual: false)]
    }
    func screenshot(display: UInt32?, maxWidth: Int?, jpeg: Bool) async throws -> Screenshot {
        guard display == nil || display == 1 else { throw AgentHostError.noSuchDisplay(display!) }
        return Screenshot(data: Data([1, 2, 3]), mimeType: "image/png", display: 1, width: 756, height: 491,
                          pointsPerPixel: 2)
    }
    func perform(_ action: AgentAction) async throws { performed.append(action) }
    func state() async -> HostState {
        HostState(cursor: CursorPosition(display: 1, x: 10, y: 20), appName: "Finder", screenLocked: false)
    }
    func openApp(_ nameOrBundleID: String) async throws -> String {
        guard nameOrBundleID.lowercased() == "textedit" else { throw AgentHostError.notFound("no app") }
        opened.append(nameOrBundleID)
        return "TextEdit"
    }
    func createVirtualDisplay(width: Int, height: Int, hiDPI: Bool) async throws -> UInt32 { 77 }
    func removeVirtualDisplay(_ id: UInt32) async -> Bool { id == 77 }
}

final class TestClock: @unchecked Sendable {
    var now: TimeInterval = 1000
}

final class EventLog: @unchecked Sendable {
    var events: [AgentEvent] = []
}

final class AgentAPITests: XCTestCase {
    private var host: FakeAgentHost!
    private var store: AgentTokenStore!
    private var secret = ""
    private var human: HumanActivity!
    private let clock = TestClock()
    private let log = EventLog()
    private var events: [AgentEvent] { log.events }
    private var now: TimeInterval {
        get { clock.now }
        set { clock.now = newValue }
    }
    private var api: AgentAPI!
    private var storeURL: URL!

    override func setUp() {
        host = FakeAgentHost()
        storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString).json")
        store = AgentTokenStore(url: storeURL)
        secret = store.create(name: "tester").secret
        let clock = clock
        let log = log
        log.events = []
        human = HumanActivity { clock.now }
        api = AgentAPI(host: host, tokens: store, human: human, port: { 3390 }, clock: { clock.now },
                       onEvent: { log.events.append($0) })
    }

    override func tearDown() { try? FileManager.default.removeItem(at: storeURL) }

    private func request(_ method: String, _ path: String, body: String = "", token: String? = nil,
                         headers: [String: String] = [:]) async -> HTTPResponse {
        var all = ["host": "127.0.0.1:3390", "authorization": "Bearer \(token ?? secret)"]
        all.merge(headers) { $1 }
        let parts = path.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        for item in URLComponents(string: path)?.queryItems ?? [] { query[item.name] = item.value }
        return await api.handle(HTTPRequest(method: method, path: String(parts[0]), query: query, headers: all,
                                            body: Data(body.utf8)))
    }

    private func json(_ response: HTTPResponse) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
    }

    func testRequiresTokenAndThrottles() async {
        let health = await request("GET", "/v1/health", token: "nope")
        XCTAssertEqual(health.status, 200, "health needs no token")
        let missing = await request("GET", "/v1/displays", token: "")
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(events.last?.allowed, false)
        for _ in 0..<10 { _ = await request("GET", "/v1/displays", token: "ct_wrong") }
        let throttled = await request("GET", "/v1/displays")
        XCTAssertEqual(throttled.status, 429, "even the right token waits out the throttle")
        now += 61
        let recovered = await request("GET", "/v1/displays")
        XCTAssertEqual(recovered.status, 200)
    }

    func testRefusesBrowserAndRebinding() async {
        let origin = await request("GET", "/v1/displays", headers: ["origin": "https://evil.example"])
        XCTAssertEqual(origin.status, 403)
        let rebinding = await request("GET", "/v1/displays", headers: ["host": "evil.example:3390"])
        XCTAssertEqual(rebinding.status, 403)
    }

    func testScreenshotInputAndAudit() async {
        let shot = await request("GET", "/v1/screenshot?max_width=800")
        XCTAssertEqual(shot.status, 200)
        XCTAssertEqual(shot.contentType, "image/png")
        XCTAssertEqual(shot.headers["X-ClawTank-Points-Per-Pixel"], "2.0000")
        let input = await request("POST", "/v1/input", body: #"{"actions":[{"type":"click","x":5,"y":6}]}"#)
        XCTAssertEqual(input.status, 200)
        XCTAssertEqual(host.performed, [.click(display: nil, x: 5, y: 6, button: .left, count: 1)])
        let opened = await request("POST", "/v1/apps/open", body: #"{"name":"textedit"}"#)
        XCTAssertEqual(json(opened)["app"] as? String, "TextEdit")
        let state = await request("GET", "/v1/state")
        XCTAssertEqual((json(state)["frontmost_app"] as? [String: Any])?["name"] as? String, "Finder")
        let display = await request("POST", "/v1/virtual-displays", body: #"{"width":1280,"height":800}"#)
        XCTAssertEqual(json(display)["id"] as? Int, 77)
        let removed = await request("DELETE", "/v1/virtual-displays/77")
        XCTAssertEqual(removed.status, 200)
        XCTAssertEqual(events.map(\.action), [
            "screenshot of display 1 (756×491)", "left click at 5,6", "open app TextEdit", "read state",
            "create virtual display 77 (1280×800)", "remove virtual display 77"
        ], "every action is reported for the audit log")
        XCTAssertTrue(events.allSatisfy { $0.allowed && $0.agent == "tester" })
    }

    func testHumanWins() async {
        human.touch()
        now += 1
        let refused = await request("POST", "/v1/input", body: #"{"type":"key","key":"return"}"#)
        XCTAssertEqual(refused.status, 409)
        XCTAssertTrue(host.performed.isEmpty)
        XCTAssertEqual(events.last?.allowed, false)
        let openRefused = await request("POST", "/v1/apps/open", body: #"{"name":"textedit"}"#)
        XCTAssertEqual(openRefused.status, 409)
        let screenshot = await request("GET", "/v1/screenshot")
        XCTAssertEqual(screenshot.status, 200, "looking is still allowed")
        now += AgentAPI.humanGraceSeconds
        let allowed = await request("POST", "/v1/input", body: #"{"type":"key","key":"return"}"#)
        XCTAssertEqual(allowed.status, 200)
    }

    func testErrors() async {
        let unknown = await request("GET", "/v1/nope")
        XCTAssertEqual(unknown.status, 404)
        let method = await request("DELETE", "/v1/screenshot")
        XCTAssertEqual(method.status, 405)
        let badBody = await request("POST", "/v1/input", body: "{")
        XCTAssertEqual(badBody.status, 400)
        let noDisplay = await request("GET", "/v1/screenshot?display=9")
        XCTAssertEqual(noDisplay.status, 404)
        let noApp = await request("POST", "/v1/apps/open", body: #"{"name":"Nonexistent"}"#)
        XCTAssertEqual(noApp.status, 404)
        let notOurs = await request("DELETE", "/v1/virtual-displays/1")
        XCTAssertEqual(notOurs.status, 404)
    }
}

final class FindAppTests: XCTestCase {
    func testFindsInstalledAppsOnly() {
        XCTAssertEqual(MacAgentHost.findApp("textedit")?.lastPathComponent, "TextEdit.app")
        XCTAssertEqual(MacAgentHost.findApp("com.apple.TextEdit")?.lastPathComponent, "TextEdit.app")
        XCTAssertNil(MacAgentHost.findApp("../../bin/sh"))
        XCTAssertNil(MacAgentHost.findApp("/System/Applications/TextEdit.app"))
        XCTAssertNil(MacAgentHost.findApp("NoSuchApp-\(UUID().uuidString)"))
    }
}
