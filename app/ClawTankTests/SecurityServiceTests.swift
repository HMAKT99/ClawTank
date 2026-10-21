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
}
