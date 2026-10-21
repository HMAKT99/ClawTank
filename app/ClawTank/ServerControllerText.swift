// Pure helpers for ServerController: human wording for core events and errors, peer/host
// formatting. Static and side-effect free, so they're unit-tested directly.

import AppKit
import Foundation
import SystemConfiguration

extension ServerController {
    func copyPassword() { Self.copyToPasteboard(password) }
    func copyFingerprint() { Self.copyToPasteboard(fingerprint) }
    func copyAddress() { Self.copyToPasteboard(address) }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    nonisolated static func describeRefusal(_ reason: String, ip: String) -> String {
        switch reason {
        case "lan-only": "Blocked \(ip): not on your local network"
        case "allowlist": "Blocked \(ip): not on the allowlist"
        case "locked-out": "Blocked \(ip): locked out after failed logins"
        default: "Blocked \(ip)"
        }
    }

    /// Short, human wording for common core errors (the raw text stays in the unified log).
    nonisolated static func friendlyDetail(_ raw: String) -> String {
        let text = raw.lowercased()
        if text.contains("logondenied") || text.contains("no candidate credential") || text.contains("credssp") {
            return "Wrong username or password"
        }
        if text.contains("close_notify") || text.contains("connection reset") || text.contains("broken pipe")
            || text.contains("unexpected eof") {
            return "Client closed the connection"
        }
        if text.contains("tls") || text.contains("certificate") {
            return "TLS handshake failed (client may have rejected the certificate)"
        }
        return raw.count > 120 ? String(raw.prefix(117)) + "…" : raw
    }

    /// "192.168.1.5:51234" → "192.168.1.5"; "[fe80::1]:5" → "fe80::1".
    nonisolated static func ipOnly(_ peer: String) -> String {
        if peer.hasPrefix("["), let end = peer.firstIndex(of: "]") {
            return String(peer[peer.index(after: peer.startIndex)..<end])
        }
        guard peer.filter({ $0 == ":" }).count == 1, let colon = peer.lastIndex(of: ":") else { return peer }
        return String(peer[..<colon])
    }

    /// The Bonjour name clients can use, e.g. "macmini.local".
    nonisolated static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            return "\(name).local"
        }
        return ProcessInfo.processInfo.hostName
    }

    nonisolated static func formatVideoStats(fps: Int, bytesPerSecond: Int, encodeMs: Double, skipped: Int) -> String {
        let mbit = Double(bytesPerSecond * 8) / 1_000_000
        var text = String(format: "%d fps · %.1f Mbit/s · enc %.1f ms", fps, mbit, encodeMs)
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }
}
