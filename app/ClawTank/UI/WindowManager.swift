// Opens ClawTank's windows (setup, settings, connection log). The app lives in the menu bar
// (LSUIElement), so windows are plain NSWindows hosting SwiftUI views, brought to the front
// explicitly; one instance of each is reused.

import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    enum Kind: String { case setup, settings, log }

    private var windows: [Kind: NSWindow] = [:]
    private let server: ServerController

    init(server: ServerController) {
        self.server = server
    }

    func show(_ kind: Kind) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ kind: Kind) {
        windows[kind]?.close()
    }

    private struct Content {
        let title: String
        let view: AnyView
        let size: NSSize
    }

    private func content(for kind: Kind) -> Content {
        switch kind {
        case .setup:
            Content(title: "Set Up ClawTank",
                    view: AnyView(OnboardingView(server: server, settings: server.settings) { [weak self] in
                        self?.close(.setup)
                    }),
                    size: NSSize(width: 620, height: 520))
        case .settings:
            Content(title: "ClawTank Settings", view: AnyView(SettingsView(server: server, settings: server.settings)),
                    size: NSSize(width: 560, height: 460))
        case .log:
            Content(title: "Connection Log", view: AnyView(ConnectionLogView(audit: server.audit)),
                    size: NSSize(width: 760, height: 440))
        }
    }

    private func makeWindow(_ kind: Kind) -> NSWindow {
        let content = content(for: kind)
        let (title, view, size) = (content.title, content.view, content.size)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                              defer: false)
        window.title = title
        window.contentViewController = NSHostingController(rootView: view)
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}
