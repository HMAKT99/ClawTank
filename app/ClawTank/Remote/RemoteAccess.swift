// Remote access without port forwarding: ClawTank stays LAN-only and relies on Tailscale (a
// WireGuard mesh VPN) for reaching the Mac from anywhere. ClawTank's LAN-only filter already
// accepts Tailscale's address ranges (100.64.0.0/10 and fd7a:115c:a1e0::/48), so nothing is ever
// exposed to the public internet (ADR-022).
//
// This service only *detects* Tailscale and reports how to connect: it reads
// `tailscale status --json` from the CLI that ships inside Tailscale.app (or Homebrew), and falls
// back to scanning interfaces for a tailnet address. It never changes Tailscale's settings.

import Foundation

enum TailscaleState: Equatable, Sendable {
    case notInstalled
    /// Installed but not connected (logged out, stopped, or the daemon isn't running).
    case notRunning(reason: String)
    case running(dnsName: String?, ipv4: String?, tailnet: String?)
    /// No CLI found, but an interface has a tailnet address (e.g. standalone or other client).
    case addressOnly(ipv4: String)

    /// What a remote client should type as the PC name, if reachable.
    var remoteAddress: String? {
        switch self {
        case .running(let dns, let ip, _): dns ?? ip
        case .addressOnly(let ip): ip
        default: nil
        }
    }

    var summary: String {
        switch self {
        case .notInstalled: "Tailscale isn't installed"
        case .notRunning(let reason): "Tailscale is installed but not connected (\(reason))"
        case .running(let dns, let ip, let tailnet):
            "Reachable from anywhere as \(dns ?? ip ?? "?")" + (tailnet.map { " on \($0)" } ?? "")
        case .addressOnly(let ip): "Tailnet address \(ip) (Tailscale CLI not found)"
        }
    }
}

enum RemoteAccess {
    static let cliCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale"
    ]

    /// Detects Tailscale (blocking up to ~3 s; call off the main thread).
    static func detect(fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       run: (String, [String]) -> Data? = runProcess,
                       interfaceAddresses: () -> [String] = ipv4Addresses) -> TailscaleState {
        if let cli = cliCandidates.first(where: fileExists) {
            guard let json = run(cli, ["status", "--json"]) else { return .notRunning(reason: "not responding") }
            return parseStatus(json)
        }
        if let ip = interfaceAddresses().first(where: isTailnetIPv4) {
            return .addressOnly(ipv4: ip)
        }
        return .notInstalled
    }

    /// Parses `tailscale status --json`.
    static func parseStatus(_ data: Data) -> TailscaleState {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .notRunning(reason: "unreadable status")
        }
        let state = root["BackendState"] as? String ?? "Unknown"
        guard state == "Running" else {
            let reason = switch state {
            case "NeedsLogin": "needs login"
            case "Stopped": "turned off"
            case "Starting": "starting"
            default: state.lowercased()
            }
            return .notRunning(reason: reason)
        }
        let ownNode = root["Self"] as? [String: Any]
        let dns = (ownNode?["DNSName"] as? String).map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }
            .flatMap { $0.isEmpty ? nil : $0 }
        let ips = ownNode?["TailscaleIPs"] as? [String] ?? []
        let tailnet = (root["CurrentTailnet"] as? [String: Any])?["Name"] as? String
        return .running(dnsName: dns, ipv4: ips.first(where: { !$0.contains(":") }), tailnet: tailnet)
    }

    /// 100.64.0.0/10 (Tailscale's IPv4 range; also used by carrier-grade NAT).
    static func isTailnetIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }

    static func runProcess(_ path: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        // Output goes to a temp file: a pipe would block the child once `status --json` (one entry
        // per peer) outgrows the pipe buffer, since we only read after it exits.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("clawtank-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: output.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: output) else { return nil }
        defer { try? FileManager.default.removeItem(at: output) }
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        try? handle.close()
        if process.isRunning {
            process.terminate()
            return nil
        }
        return process.terminationStatus == 0 ? try? Data(contentsOf: output) : nil
    }

    static func ipv4Addresses() -> [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                == 0, let text = String(bytes: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8) {
                result.append(text)
            }
        }
        return result
    }

    /// "Wake for network access" (pmset womp) — needed to reach a sleeping Mac remotely.
    static func wakeForNetworkAccess(run: (String, [String]) -> Data? = runProcess) -> Bool? {
        guard let data = run("/usr/bin/pmset", ["-g"]), let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        for line in text.split(separator: "\n") where line.trimmingCharacters(in: .whitespaces).hasPrefix("womp") {
            return line.split(separator: " ").last == "1"
        }
        return nil
    }
}
