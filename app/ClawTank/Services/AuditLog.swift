// Local record of every connection attempt: when, from where, as whom, and what happened.
// JSON lines in Application Support, rotated at 1 MB (one previous file kept). It holds no
// secrets: only addresses, the username clients use, and outcomes.

import Foundation

struct AuditEntry: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        case connected, disconnected, failedLogin, refused, lockedOut
    }

    var id: String { "\(time.timeIntervalSince1970)-\(peer)-\(outcome.rawValue)" }
    let time: Date
    let peer: String
    let user: String?
    let outcome: Outcome
    let detail: String?

    var summary: String {
        switch outcome {
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .failedLogin: "Failed login"
        case .refused: "Refused"
        case .lockedOut: "Locked out"
        }
    }
}

final class AuditLog: @unchecked Sendable {
    let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawTank/audit.log")
    }

    init(url: URL = AuditLog.defaultURL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    func append(_ entry: AuditEntry) {
        lock.withLock {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard var line = try? encoder.encode(entry) else { return }
            line.append(0x0A)
            let files = FileManager.default
            try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? files.attributesOfItem(atPath: url.path)[.size]) as? Int, size + line.count > maxBytes {
                let previous = url.appendingPathExtension("1")
                try? files.removeItem(at: previous)
                try? files.moveItem(at: url, to: previous)
            }
            if !files.fileExists(atPath: url.path) {
                files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Newest first, from the current and the previous file.
    func entries(limit: Int = 500) -> [AuditEntry] {
        lock.withLock {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var all: [AuditEntry] = []
            for file in [url.appendingPathExtension("1"), url] {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    if let entry = try? decoder.decode(AuditEntry.self, from: Data(line.utf8)) { all.append(entry) }
                }
            }
            return Array(all.reversed().prefix(limit))
        }
    }
}
