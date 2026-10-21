// Viewer for the audit log: every connection attempt, newest first.

import AppKit
import SwiftUI

struct ConnectionLogView: View {
    let audit: AuditLog
    @State private var entries: [AuditEntry] = []

    var body: some View {
        VStack(alignment: .leading) {
            Table(entries) {
                TableColumn("Time") { Text($0.time.formatted(date: .abbreviated, time: .standard)) }
                    .width(min: 150, ideal: 170)
                TableColumn("Address", value: \.peer).width(min: 110, ideal: 130)
                TableColumn("User") { Text($0.user ?? "—") }.width(min: 70, ideal: 90)
                TableColumn("Event") { entry in
                    Label(entry.summary, systemImage: symbol(entry.outcome))
                        .foregroundStyle(color(entry.outcome))
                }
                .width(min: 110, ideal: 120)
                TableColumn("Detail") { Text($0.detail ?? "").lineLimit(1).help($0.detail ?? "") }
            }
            HStack {
                Text("\(entries.count) entries").foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([audit.url]) }
                Button("Refresh") { reload() }.keyboardShortcut("r")
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 380)
        .onAppear(perform: reload)
    }

    private func reload() {
        entries = audit.entries()
    }

    private func symbol(_ outcome: AuditEntry.Outcome) -> String {
        switch outcome {
        case .connected: "checkmark.circle"
        case .disconnected: "xmark.circle"
        case .failedLogin: "exclamationmark.triangle"
        case .refused: "hand.raised"
        case .lockedOut: "lock"
        }
    }

    private func color(_ outcome: AuditEntry.Outcome) -> Color {
        switch outcome {
        case .connected, .disconnected: .primary
        case .failedLogin, .refused: .orange
        case .lockedOut: .red
        }
    }
}
