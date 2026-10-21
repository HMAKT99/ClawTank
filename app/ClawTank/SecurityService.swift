// Secrets for the RDP listener: the TLS identity (certificate + private key) and the NLA
// password. Stored as Keychain generic-password items so they survive restarts and the
// certificate fingerprint stays stable. Storage sits behind `SecretStore` so tests use a fake.
//
// Phase 1 generates a random password and shows it in the menu; Phase 5 onboarding lets the
// user choose one (ADR-003).

import Foundation
import Security

/// Minimal secret storage used by `SecurityService`.
protocol SecretStore: Sendable {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, for account: String) throws
}

enum SecretStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// Keychain-backed store (login keychain, this device only, available after first unlock so a
/// headless Mac can serve sessions after a reboot + auto-login).
struct KeychainStore: SecretStore {
    let service: String

    func read(_ account: String) throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw SecretStoreError.keychain(status)
        }
    }

    func write(_ data: Data, for account: String) throws {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let deleteStatus = SecItemDelete(match as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw SecretStoreError.keychain(deleteStatus)
        }
        var add = match
        add[kSecValueData] = data
        add[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel] = "ClawTank (\(account))"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status) }
    }
}

struct TLSIdentity: Equatable, Sendable {
    let certificateDER: Data
    let privateKeyDER: Data
    let fingerprint: String
}

enum SecurityError: Error, Equatable {
    case identityGenerationFailed
    case randomGenerationFailed
}

final class SecurityService: Sendable {
    private enum Account {
        static let certificate = "tls-certificate"
        static let privateKey = "tls-private-key"
        static let password = "rdp-password"
    }

    /// Unambiguous characters (no 0/O, 1/l/I) so the password is easy to read off the screen.
    static let passwordAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789")
    static let passwordLength = 20

    private let store: SecretStore
    private let core: CoreBridge

    init(store: SecretStore = KeychainStore(service: "dev.clawtank.ClawTank"), core: CoreBridge = .shared) {
        self.store = store
        self.core = core
    }

    /// The account name clients log in with: the current macOS short user name.
    var username: String { NSUserName() }

    /// Returns the stored TLS identity, generating and storing one on first use.
    func loadOrCreateIdentity(commonName: String) throws -> TLSIdentity {
        if let cert = try store.read(Account.certificate), let key = try store.read(Account.privateKey),
           let fingerprint = core.fingerprint(certificateDER: cert) {
            return TLSIdentity(certificateDER: cert, privateKeyDER: key, fingerprint: fingerprint)
        }
        guard let (cert, key) = core.generateTLSIdentity(commonName: commonName),
              let fingerprint = core.fingerprint(certificateDER: cert) else {
            throw SecurityError.identityGenerationFailed
        }
        try store.write(key, for: Account.privateKey)
        try store.write(cert, for: Account.certificate)
        return TLSIdentity(certificateDER: cert, privateKeyDER: key, fingerprint: fingerprint)
    }

    /// Returns the stored RDP password, generating and storing one on first use.
    func loadOrCreatePassword() throws -> String {
        if let data = try store.read(Account.password), let password = String(data: data, encoding: .utf8),
           !password.isEmpty {
            return password
        }
        let password = try Self.generatePassword()
        try store.write(Data(password.utf8), for: Account.password)
        return password
    }

    /// Uniformly random password from `passwordAlphabet` (rejection sampling, no modulo bias).
    static func generatePassword(length: Int = passwordLength) throws -> String {
        let alphabet = passwordAlphabet
        let limit = 256 - (256 % alphabet.count)
        var result: [Character] = []
        var buffer = [UInt8](repeating: 0, count: 64)
        while result.count < length {
            guard SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer) == errSecSuccess else {
                throw SecurityError.randomGenerationFailed
            }
            for byte in buffer where Int(byte) < limit && result.count < length {
                result.append(alphabet[Int(byte) % alphabet.count])
            }
        }
        return String(result)
    }
}
