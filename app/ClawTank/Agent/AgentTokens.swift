// Per-agent bearer tokens for the Agent API. A token is shown once when created; only its
// SHA-256 is stored (agents.json in Application Support, mode 0600), so the file alone can't be
// used to authenticate. Revoking deletes the hash.

import CryptoKit
import Foundation

struct AgentToken: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    let hash: String
    let created: Date
    var lastUsed: Date?
}

final class AgentTokenStore: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var tokens: [AgentToken]

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawTank/agents.json")
    }

    init(url: URL = AgentTokenStore.defaultURL) {
        self.url = url
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        tokens = (try? Data(contentsOf: url)).flatMap { try? decoder.decode([AgentToken].self, from: $0) } ?? []
    }

    var all: [AgentToken] { lock.withLock { tokens } }

    /// Creates a token for `name`; returns the secret, which is never stored.
    func create(name: String) -> (AgentToken, secret: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
        let secret = "ct_" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = AgentToken(id: UUID().uuidString, name: name, hash: Self.digest(secret), created: Date())
        lock.withLock {
            tokens.append(token)
            save()
        }
        return (token, secret)
    }

    func revoke(id: String) {
        lock.withLock {
            tokens.removeAll { $0.id == id }
            save()
        }
    }

    /// The token matching `secret`, if any (constant-time over each stored hash).
    func verify(_ secret: String) -> AgentToken? {
        let candidate = Array(Self.digest(secret).utf8)
        return lock.withLock {
            var match: Int?
            for (index, token) in tokens.enumerated() {
                let stored = Array(token.hash.utf8)
                var diff = UInt8(stored.count == candidate.count ? 0 : 1)
                for (lhs, rhs) in zip(stored, candidate) { diff |= lhs ^ rhs }
                if diff == 0 { match = index }
            }
            guard let match else { return nil }
            // Persist "last used" at most once a minute.
            let now = Date()
            if tokens[match].lastUsed.map({ now.timeIntervalSince($0) > 60 }) ?? true {
                tokens[match].lastUsed = now
                save()
            }
            return tokens[match]
        }
    }

    static func digest(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(tokens) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
