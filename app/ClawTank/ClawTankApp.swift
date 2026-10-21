// ClawTank — menu-bar host app.
//
// Phase 1: starts the RDP server at launch (TLS + NLA, static test frame) and shows how to
// connect: address, username, password and certificate fingerprint. Later phases add live
// capture, input and the services described in docs/architecture.md.

import SwiftUI

@main
struct ClawTankApp: App {
    @StateObject private var server: ServerController
    private let core = CoreBridge.shared

    init() {
        let controller = ServerController()
        // When the app is only hosting unit tests, don't touch the Keychain or bind port 3389.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            controller.start()
        }
        _server = StateObject(wrappedValue: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(server: server, coreVersion: core.version)
        } label: {
            Image(systemName: server.menuBarSymbol)
                .accessibilityLabel(server.statusText)
        }
    }
}

struct StatusMenu: View {
    @ObservedObject var server: ServerController
    let coreVersion: String

    var body: some View {
        Text(server.statusText)
        if let notice = server.lastNotice {
            Text(notice)
        }
        Divider()
        Button("Copy Address (\(server.hostName))") { server.copyAddress() }
        Text("Username: \(server.username)")
        Button("Copy Password") { server.copyPassword() }
            .disabled(!server.isRunning)
        Button("Copy Certificate Fingerprint") { server.copyFingerprint() }
            .disabled(server.fingerprint.isEmpty)
        if !server.fingerprint.isEmpty {
            Text("SHA-256 \(server.fingerprint.prefix(23))…")
        }
        Divider()
        if server.isRunning {
            Button("Stop Server") { server.stop() }
        } else {
            Button("Start Server") { server.start() }
        }
        Divider()
        Text("ClawTank \(Bundle.main.shortVersion) · core \(coreVersion)")
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
        case .stopped: "Server stopped"
        case .listening(let port): "Ready — \(hostName)\(port == 3389 ? "" : ":\(port)")"
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
