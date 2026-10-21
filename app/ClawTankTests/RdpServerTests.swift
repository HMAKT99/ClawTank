import XCTest
@testable import ClawTank
import ClawTankCore

/// Exercises the Swift ↔ Rust server boundary: start on a free port, receive events, stop.
final class RdpServerTests: XCTestCase {
    private func makeConfiguration(port: UInt16 = 0) throws -> RdpServer.Configuration {
        let identity = try SecurityService(store: InMemoryStore()).loadOrCreateIdentity(commonName: "test.local")
        return RdpServer.Configuration(
            bindIP: "127.0.0.1", port: port, username: "tester", password: "secret-password", identity: identity)
    }

    func testStartReportsListeningAndStopReportsStopped() throws {
        let listening = expectation(description: "listening")
        let stopped = expectation(description: "stopped")
        let server = try RdpServer(configuration: makeConfiguration()) { event in
            switch event {
            case .listening: listening.fulfill()
            case .stopped: stopped.fulfill()
            default: break
            }
        }
        XCTAssertNotEqual(server.port, 0)
        wait(for: [listening], timeout: 5)
        server.stop()
        wait(for: [stopped], timeout: 5)
        server.stop() // idempotent
    }

    func testPortInUseFailsWithBindError() throws {
        let first = try RdpServer(configuration: makeConfiguration()) { _ in }
        defer { first.stop() }
        XCTAssertThrowsError(try RdpServer(configuration: makeConfiguration(port: first.port)) { _ in }) { error in
            XCTAssertEqual(error as? RdpServer.StartError, .failed(status: CT_STATUS_BIND_FAILED.rawValue))
        }
    }

    func testPeerFormatting() {
        XCTAssertEqual(ServerController.ipOnly("192.168.1.5:51234"), "192.168.1.5")
        XCTAssertEqual(ServerController.ipOnly("[fe80::1]:5000"), "fe80::1")
    }
}
