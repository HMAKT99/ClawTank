// "Copy diagnostics": a .zip a user can attach to a bug report. It contains recent ClawTank
// log entries, settings, the connection log, versions and the display list. It never includes
// the RDP password or the TLS private key (they are never read here).

import AppKit
import Foundation
import OSLog

enum Diagnostics {
    /// Writes the bundle's files into `folder` (exposed for tests).
    static func writeContents(to folder: URL, settings: [String: String], audit: AuditLog,
                              coreVersion: String, since: Date = Date().addingTimeInterval(-3 * 3600)) throws {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        let process = ProcessInfo.processInfo
        var info = [
            "ClawTank \(Bundle.main.shortVersion) (core \(coreVersion))",
            "macOS \(process.operatingSystemVersionString)",
            "Hardware \(hardwareModel()) · \(process.processorCount) cores · "
                + "\(process.physicalMemory / 1_073_741_824) GB",
            "Generated \(ISO8601DateFormatter().string(from: Date()))",
            "",
            "Displays:"
        ]
        for id in CGVirtualDisplayProvider.onlineDisplays() {
            let bounds = CGDisplayBounds(id)
            let virtual = CGDisplayVendorNumber(id) == CGVirtualDisplayHandle.vendorID ? " (ClawTank virtual)" : ""
            info.append("  \(id): \(Int(bounds.width))x\(Int(bounds.height)) pt\(virtual)")
        }
        info += ["", "Settings:"] + settings.keys.sorted().map { "  \($0) = \(settings[$0] ?? "")" }
        try info.joined(separator: "\n").write(to: folder.appendingPathComponent("info.txt"), atomically: true,
                                               encoding: .utf8)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        try encoder.encode(audit.entries(limit: 1000)).write(to: folder.appendingPathComponent("connections.json"))

        try recentLogs(since: since).write(to: folder.appendingPathComponent("log.txt"), atomically: true,
                                           encoding: .utf8)
    }

    /// Zips the bundle to `destination` with ditto.
    static func export(to destination: URL, settings: [String: String], audit: AuditLog,
                       coreVersion: String) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClawTank-diagnostics-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeContents(to: folder, settings: settings, audit: audit, coreVersion: coreVersion)
        try? FileManager.default.removeItem(at: destination)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, destination.path]
        try ditto.run()
        ditto.waitUntilExit()
        if ditto.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func recentLogs(since: Date) -> String {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since)) else {
            return "(log store unavailable)"
        }
        let formatter = ISO8601DateFormatter()
        return entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "dev.clawtank.ClawTank" }
            .map { "\(formatter.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
            .joined(separator: "\n")
    }

    private static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let bytes = model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? "unknown"
    }
}
