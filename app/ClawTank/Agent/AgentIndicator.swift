// A small always-on-top badge while an agent is in control, on every display so it's seen both
// at the Mac and in RDP sessions. Its Stop button turns the Agent API off.

import AppKit
import SwiftUI

@MainActor
final class AgentIndicator {
    private var panels: [NSPanel] = []
    private let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }

    func show(agent: String) {
        hide()
        for screen in NSScreen.screens {
            let view = NSHostingView(rootView: Badge(agent: agent, onStop: onStop))
            let size = view.fittingSize
            let visible = screen.visibleFrame
            let frame = NSRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 8,
                               width: size.width, height: size.height)
            let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                                defer: false)
            panel.contentView = view
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.orderFrontRegardless()
            panels.append(panel)
        }
    }

    func hide() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }

    private struct Badge: View {
        let agent: String
        let onStop: () -> Void

        var body: some View {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.rays")
                Text("Agent “\(agent)” is in control").font(.callout.weight(.medium))
                Button("Stop", action: onStop).controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.orange.opacity(0.92), in: Capsule())
            .foregroundStyle(.black)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Agent \(agent) is in control. Stop button.")
        }
    }
}
