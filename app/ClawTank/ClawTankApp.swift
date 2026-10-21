// ClawTank — menu-bar host app.
//
// Phase 0: proves the Swift ↔ Rust link by showing the core version in the menu.
// Later phases add SessionManager and the capture/encode/input services described in
// docs/architecture.md.

import SwiftUI

@main
struct ClawTankApp: App {
    private let core = CoreBridge.shared

    var body: some Scene {
        MenuBarExtra("ClawTank", systemImage: "display") {
            Text("ClawTank \(Bundle.main.shortVersion)")
            Text("core v\(core.version)")
            Divider()
            Button("Quit ClawTank") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }
}
