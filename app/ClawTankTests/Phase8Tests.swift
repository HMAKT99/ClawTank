import XCTest
@testable import ClawTank

final class RemoteAccessTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testParsesRunningStatus() {
        let state = RemoteAccess.parseStatus(json("""
        {"BackendState":"Running",
         "Self":{"DNSName":"studio.tail1234.ts.net.","TailscaleIPs":["fd7a:115c:a1e0::1","100.101.102.103"]},
         "CurrentTailnet":{"Name":"me@example.com"}}
        """))
        XCTAssertEqual(state, .running(dnsName: "studio.tail1234.ts.net", ipv4: "100.101.102.103",
                                       tailnet: "me@example.com"))
        XCTAssertEqual(state.remoteAddress, "studio.tail1234.ts.net", "MagicDNS name preferred, trailing dot stripped")
    }

    func testFallsBackToIPWithoutMagicDNS() {
        let state = RemoteAccess.parseStatus(json("""
        {"BackendState":"Running","Self":{"DNSName":"","TailscaleIPs":["100.70.0.5"]}}
        """))
        XCTAssertEqual(state.remoteAddress, "100.70.0.5")
    }

    func testNotRunningStates() {
        XCTAssertEqual(RemoteAccess.parseStatus(json(#"{"BackendState":"NeedsLogin"}"#)),
                       .notRunning(reason: "needs login"))
        XCTAssertEqual(RemoteAccess.parseStatus(json(#"{"BackendState":"Stopped"}"#)),
                       .notRunning(reason: "turned off"))
        XCTAssertEqual(RemoteAccess.parseStatus(json("not json")), .notRunning(reason: "unreadable status"))
        XCTAssertNil(TailscaleState.notRunning(reason: "x").remoteAddress)
    }

    func testDetectPaths() {
        let running = json(#"{"BackendState":"Running","Self":{"TailscaleIPs":["100.64.1.2"]}}"#)
        XCTAssertEqual(RemoteAccess.detect(fileExists: { _ in true }, run: { _, _ in running },
                                           interfaceAddresses: { [] }).remoteAddress, "100.64.1.2")
        XCTAssertEqual(RemoteAccess.detect(fileExists: { _ in true }, run: { _, _ in nil }, interfaceAddresses: { [] }),
                       .notRunning(reason: "not responding"))
        XCTAssertEqual(RemoteAccess.detect(fileExists: { _ in false }, run: { _, _ in nil },
                                           interfaceAddresses: { ["192.168.1.4", "100.88.9.10"] }),
                       .addressOnly(ipv4: "100.88.9.10"))
        XCTAssertEqual(RemoteAccess.detect(fileExists: { _ in false }, run: { _, _ in nil },
                                           interfaceAddresses: { ["192.168.1.4"] }), .notInstalled)
    }

    func testTailnetRange() {
        XCTAssertTrue(RemoteAccess.isTailnetIPv4("100.64.0.1"))
        XCTAssertTrue(RemoteAccess.isTailnetIPv4("100.127.255.254"))
        XCTAssertFalse(RemoteAccess.isTailnetIPv4("100.128.0.1"))
        XCTAssertFalse(RemoteAccess.isTailnetIPv4("100.63.0.1"))
        XCTAssertFalse(RemoteAccess.isTailnetIPv4("10.0.0.1"))
        XCTAssertFalse(RemoteAccess.isTailnetIPv4("garbage"))
    }

    func testWakeForNetworkParsing() {
        let pmset = { (womp: String) in { (_: String, _: [String]) -> Data? in
            Data("System-wide power settings:\nCurrently in use:\n standby 1\n womp \(womp)\n sleep 1\n".utf8)
        } }
        XCTAssertEqual(RemoteAccess.wakeForNetworkAccess(run: pmset("1")), true)
        XCTAssertEqual(RemoteAccess.wakeForNetworkAccess(run: pmset("0")), false)
        XCTAssertNil(RemoteAccess.wakeForNetworkAccess(run: { _, _ in Data("sleep 1\n".utf8) }))
    }

    func testRunProcessReadsLargeOutput() {
        // More than a pipe buffer (64 KiB) of output must not stall.
        let data = RemoteAccess.runProcess("/bin/sh", ["-c", "head -c 300000 /dev/zero"])
        XCTAssertEqual(data?.count, 300_000)
        XCTAssertNotNil(RemoteAccess.wakeForNetworkAccess(), "real pmset on this Mac")
    }
}
