// Secrets for the RDP listener: the TLS identity (certificate + private key) and the NLA
// password, persisted so they survive restarts and the certificate fingerprint stays stable.
// Developer ID builds use the Keychain. Ad-hoc dev builds use an owner-only file store,
// because the login keychain ties access to each ad-hoc build's exact hash and would prompt
// for the keychain password after every rebuild (ADR-013). Tests inject a fake `SecretStore`.
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

/// Owner-only files (directory 0700, files 0600) in Application Support. Used by ad-hoc
/// (unsigned) builds only; see ADR-013.
struct FileSecretStore: SecretStore {
    let directory: URL

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawTank/secrets", isDirectory: true)
    }

    private func url(for account: String) -> URL {
        directory.appendingPathComponent("\(account).secret")
    }

    func read(_ account: String) throws -> Data? {
        let file = url(for: account)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try Data(contentsOf: file)
    }

    func write(_ data: Data, for account: String) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = url(for: account)
        // Create empty with 0600 first so the secret is never briefly world-readable.
        if !files.fileExists(atPath: file.path) {
            files.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = file
        try? mutable.setResourceValues(values)
    }
}

enum SecretStores {
    /// Keychain for Developer ID–signed builds, owner-only files for ad-hoc builds.
    static func `default`() -> SecretStore {
        isSignedWithTeamIdentifier()
            ? KeychainStore(service: "dev.clawtank.ClawTank")
            : FileSecretStore(directory: FileSecretStore.defaultDirectory)
    }

    /// True when this process's code signature carries a team identifier (Developer ID or
    /// Apple Development). Ad-hoc signatures have none.
    static func isSignedWithTeamIdentifier() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] != nil
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

    init(store: SecretStore = SecretStores.default(), core: CoreBridge = .shared) {
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
