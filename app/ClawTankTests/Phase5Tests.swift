import XCTest
@testable import ClawTank

private func temporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("clawtank-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class AuditLogTests: XCTestCase {
    func testAppendReadNewestFirstAndPermissions() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AuditLog(url: dir.appendingPathComponent("audit.log"))
        log.append(AuditEntry(time: Date(timeIntervalSince1970: 1), peer: "10.0.0.2", user: "arun",
                              outcome: .connected, detail: nil))
        log.append(AuditEntry(time: Date(timeIntervalSince1970: 2), peer: "10.0.0.3", user: nil,
                              outcome: .refused, detail: "lan-only"))
        let entries = log.entries()
        XCTAssertEqual(entries.map(\.peer), ["10.0.0.3", "10.0.0.2"])
        XCTAssertEqual(entries.first?.detail, "lan-only")
        let perms = try FileManager.default.attributesOfItem(atPath: log.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testRotationKeepsOnePreviousFile() {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AuditLog(url: dir.appendingPathComponent("audit.log"), maxBytes: 600)
        for index in 0..<20 {
            log.append(AuditEntry(time: Date(timeIntervalSince1970: Double(index)), peer: "10.0.0.\(index)",
                                  user: "u", outcome: .failedLogin, detail: "x"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: log.url.appendingPathExtension("1").path))
        let entries = log.entries()
        XCTAssertEqual(entries.first?.peer, "10.0.0.19", "newest first")
        XCTAssertLessThan(entries.count, 20, "oldest rotated away")
    }
}

final class PasswordPolicyTests: XCTestCase {
    func testRules() {
        XCTAssertEqual(PasswordPolicy.problems("short", username: "arun"), [.tooShort(minimum: 12)])
        XCTAssertTrue(PasswordPolicy.problems("password1234", username: "arun").contains(.common))
        XCTAssertTrue(PasswordPolicy.problems("aaaaaaaaaaaaaa", username: "arun").contains(.repetitive))
        XCTAssertTrue(PasswordPolicy.problems("my-arun-secret-9", username: "arun").contains(.containsUsername))
        XCTAssertEqual(PasswordPolicy.problems("correct horse battery", username: "arun"), [])
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testDefaultsPersistenceAndPresets() throws {
        let suite = "clawtank-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.port, 3389)
        XCTAssertTrue(settings.lanOnly)
        XCTAssertTrue(settings.keepAwake)
        XCTAssertEqual(settings.frameRate, 60)
        settings.quality = .lowBandwidth
        XCTAssertEqual(settings.frameRate, 30, "low bandwidth caps the frame rate")
        settings.port = 3390
        settings.allowlist = "192.168.1.0/24"
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.port, 3390)
        XCTAssertEqual(reloaded.allowlist, "192.168.1.0/24")
        XCTAssertEqual(reloaded.quality, .lowBandwidth)
        XCTAssertGreaterThan(QualityPreset.sharpText.bitRateFactor, QualityPreset.balanced.bitRateFactor)
    }
}

final class FakePower: PowerManaging {
    var isActive = false
    var begins = 0
    func begin(reason: String) -> Bool { begins += 1; isActive = true; return true }
    func end() { isActive = false }
}

@MainActor
final class ServerControllerTests: XCTestCase {
    func testPasswordChangeValidatesAndStores() throws {
        let suite = "clawtank-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = InMemoryStore()
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = ServerController(settings: AppSettings(defaults: defaults),
                                          security: SecurityService(store: store),
                                          audit: AuditLog(url: dir.appendingPathComponent("a.log")), power: FakePower())
        XCTAssertFalse(controller.setPassword("short").isEmpty, "weak password rejected")
        XCTAssertEqual(controller.setPassword("correct horse battery"), [])
        XCTAssertEqual(try store.read("rdp-password"), Data("correct horse battery".utf8))
        XCTAssertEqual(controller.password, "correct horse battery")
    }

    func testFriendlyDetails() {
        XCTAssertEqual(ServerController.friendlyDetail("custom error: LogonDenied: no candidate credential matched"),
                       "Wrong username or password")
        XCTAssertEqual(ServerController.friendlyDetail("peer closed connection without sending TLS close_notify"),
                       "Client closed the connection")
        XCTAssertEqual(ServerController.friendlyDetail("short reason"), "short reason")
    }

    func testRefusalDescriptions() {
        XCTAssertTrue(ServerController.describeRefusal("lan-only", ip: "8.8.8.8").contains("local network"))
        XCTAssertTrue(ServerController.describeRefusal("locked-out", ip: "1.2.3.4").contains("locked out"))
    }
}

@MainActor
final class DiagnosticsTests: XCTestCase {
    func testBundleHasExpectedFilesAndNoSecrets() throws {
        let dir = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = AuditLog(url: dir.appendingPathComponent("audit.log"))
        audit.append(AuditEntry(time: Date(), peer: "10.0.0.9", user: "arun", outcome: .connected, detail: nil))
        let folder = dir.appendingPathComponent("bundle")
        try Diagnostics.writeContents(to: folder, settings: ["port": "3389", "lanOnly": "true"], audit: audit,
                                      coreVersion: "0.1.0")
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        XCTAssertEqual(names, ["connections.json", "info.txt", "log.txt"])
        let info = try String(contentsOf: folder.appendingPathComponent("info.txt"), encoding: .utf8)
        XCTAssertTrue(info.contains("core 0.1.0"))
        XCTAssertTrue(info.contains("port = 3389"))
        // Diagnostics never reads secrets; make sure no stored secret names leak in by accident.
        let everything = try names.map { try String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
            .joined()
        XCTAssertFalse(everything.contains("PRIVATE KEY"))
        XCTAssertFalse(everything.contains("rdp-password"))
    }
}
