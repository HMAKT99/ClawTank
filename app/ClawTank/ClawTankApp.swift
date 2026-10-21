// ClawTank — menu-bar host app.
//
// Starts the RDP server at launch (TLS + NLA, LAN-only by default), shows first-run setup,
// and while a client is connected streams the display (virtual or physical), injects the
// client's keyboard and mouse, sends cursor shapes and keeps the Mac awake. The menu shows
// who is connected and live video stats. See docs/architecture.md.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let server: ServerController
    let windows: WindowManager

    init() {
        settings = AppSettings()
        server = ServerController(settings: settings)
        windows = WindowManager(server: server)
        // When the app is only hosting unit tests, don't touch secrets or bind the port.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        server.start()
        if !settings.hasCompletedOnboarding {
            DispatchQueue.main.async { [windows] in windows.show(.setup) }
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClawTank-diagnostics-\(Date().formatted(.iso8601.year().month().day())).zip"
        panel.allowedContentTypes = [.zip]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Diagnostics.export(to: url, settings: settings.diagnosticsSummary, audit: server.audit,
                                   coreVersion: CoreBridge.shared.version)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@main
struct ClawTankApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(model: model, server: model.server, settings: model.settings)
        } label: {
            MenuBarIcon(server: model.server)
        }
    }
}

private struct MenuBarIcon: View {
    @ObservedObject var server: ServerController
    var body: some View {
        Image(systemName: server.menuBarSymbol)
            .accessibilityLabel("ClawTank: \(server.statusText)")
    }
}

struct StatusMenu: View {
    let model: AppModel
    @ObservedObject var server: ServerController
    @ObservedObject var settings: AppSettings

    var body: some View {
        Text(server.statusText)
        if let session = server.session {
            Text("From \(session.peer) since \(session.since.formatted(date: .omitted, time: .shortened))")
            if let display = server.displayDescription { Text(display) }
            if let video = server.videoStatus { Text(video) }
            if let transfer = server.transferStatus { Text(transfer) }
            Button("Disconnect \(session.peer)") { server.disconnectClient() }
        }
        if server.screenLocked {
            Text("This Mac is locked: remote clients see only the wallpaper until it's unlocked")
        }
        if let notice = server.lastNotice {
            Text(notice)
        }
        Divider()
        Button("Copy Address (\(server.address))") { server.copyAddress() }
        if let remote = server.remote.remoteAddress {
            Button("Copy Remote Address (\(remote))") { server.copyRemoteAddress() }
        } else {
            Button("Set Up Remote Access…") { model.windows.show(.settings) }
        }
        Button("Copy Password") { server.copyPassword() }.disabled(!server.isRunning)
        if server.isRunning {
            Button("Stop Sharing") { server.stop() }
        } else {
            Button("Start Sharing") { server.start() }
        }
        Divider()
        Toggle("Show Stats Overlay", isOn: $settings.showsStatsOverlay)
        Picker("Display", selection: $settings.displayMode) {
            ForEach(DisplayMode.allCases) { Text($0.title).tag($0) }
        }
        Divider()
        Button("Settings…") { model.windows.show(.settings) }.keyboardShortcut(",")
        Button("Connection Log…") { model.windows.show(.log) }
        Button("Setup Guide…") { model.windows.show(.setup) }
        Button("Export Diagnostics…") { model.exportDiagnostics() }
        Divider()
        Text("ClawTank \(Bundle.main.shortVersion) · core \(CoreBridge.shared.version)")
        Button("Quit ClawTank") {
            server.stop()
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension ServerController {
    var statusText: String {
        switch status {
        case .stopped: "Sharing is off"
        case .listening: "Ready — connect to \(address)"
        case .connected(let peer): "Connected: \(peer)"
        case .failed(let message): "Error: \(message)"
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .stopped: "display"
        case .listening: "display"
        case .connected: "dot.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle"
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
