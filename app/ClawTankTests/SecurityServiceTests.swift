import XCTest
@testable import ClawTank

/// In-memory `SecretStore` so tests never touch the real Keychain.
final class InMemoryStore: SecretStore, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private let lock = NSLock()

    func read(_ account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func write(_ data: Data, for account: String) throws {
        lock.withLock { items[account] = data }
    }
}

final class SecurityServiceTests: XCTestCase {
    func testIdentityIsCreatedOnceAndReused() throws {
        let service = SecurityService(store: InMemoryStore())
        let first = try service.loadOrCreateIdentity(commonName: "test.local")
        let second = try service.loadOrCreateIdentity(commonName: "test.local")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.fingerprint.count, 95)
    }

    func testPasswordIsCreatedOnceAndReused() throws {
        let service = SecurityService(store: InMemoryStore())
        let first = try service.loadOrCreatePassword()
        XCTAssertEqual(first.count, SecurityService.passwordLength)
        XCTAssertEqual(try service.loadOrCreatePassword(), first)
    }

    func testGeneratedPasswordsUseAlphabetAndDiffer() throws {
        let alphabet = Set(SecurityService.passwordAlphabet)
        let passwords = try (0..<20).map { _ in try SecurityService.generatePassword() }
        XCTAssertEqual(Set(passwords).count, passwords.count)
        XCTAssertTrue(passwords.allSatisfy { $0.allSatisfy(alphabet.contains) })
    }

    func testFileStoreRoundTripsWithOwnerOnlyPermissions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileSecretStore(directory: dir)
        XCTAssertNil(try store.read("missing"))
        try store.write(Data("first-value".utf8), for: "item")
        try store.write(Data("second".utf8), for: "item")
        XCTAssertEqual(try store.read("item"), Data("second".utf8))

        func permissions(_ url: URL) throws -> Int? {
            try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        }
        let dirPerms = try permissions(dir)
        let filePerms = try permissions(dir.appendingPathComponent("item.secret"))
        XCTAssertEqual(dirPerms, 0o700)
        XCTAssertEqual(filePerms, 0o600)
    }

    func testAdHocTestHostIsNotTeamSigned() {
        XCTAssertFalse(SecretStores.isSignedWithTeamIdentifier())
    }
}
