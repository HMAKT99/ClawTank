// Settings → Remote Access: reach this Mac from anywhere via Tailscale, without opening any port
// to the internet. A guided flow that reflects the detected state.

import AppKit
import SwiftUI

struct RemoteAccessSettings: View {
    @ObservedObject var server: ServerController

    var body: some View {
        Form {
            Section {
                Label(server.remote.summary, systemImage: icon)
                    .foregroundStyle(server.remote.remoteAddress == nil ? Color.secondary : Color.green)
                    .accessibilityLabel("Remote access status: \(server.remote.summary)")
                if let address = server.remote.remoteAddress {
                    HStack {
                        Text("PC name for remote clients")
                        Spacer()
                        Text(address).font(.body.monospaced()).textSelection(.enabled)
                        Button("Copy") { server.copyRemoteAddress() }
                    }
                }
                Button("Check Again") { server.refreshRemoteAccess() }
            }
            Section("How it works") {
                Text("ClawTank only accepts connections from your local network and from Tailscale, a private "
                     + "encrypted network between your own devices. Nothing is exposed to the internet, and you "
                     + "never need to forward a port on your router.")
                    .fixedSize(horizontal: false, vertical: true)
                steps
            }
            Section("Waking this Mac remotely") {
                wake
            }
        }
        .formStyle(.grouped)
    }

    private var icon: String {
        switch server.remote {
        case .running, .addressOnly: "checkmark.shield"
        case .notRunning: "exclamationmark.triangle"
        case .notInstalled: "globe"
        }
    }

    @ViewBuilder private var steps: some View {
        switch server.remote {
        case .notInstalled:
            Text("1. Install Tailscale on this Mac and sign in.\n2. Install it on the device you'll connect from "
                 + "and sign in with the same account.\n3. Come back here: ClawTank shows the name to use.")
            Button("Get Tailscale for Mac") { open("https://tailscale.com/download/mac") }
        case .notRunning:
            Text("Open Tailscale and connect (sign in if asked). ClawTank checks again every 30 seconds.")
            Button("Open Tailscale") { NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Tailscale.app")) }
        case .running, .addressOnly:
            Text("On the other device: connect Tailscale, then add a PC in Windows App or mstsc with the name above, "
                 + "your username \(server.username) and your ClawTank password.")
        }
    }

    @ViewBuilder private var wake: some View {
        switch server.wakeForNetwork {
        case true?:
            Label("Wake for network access is on", systemImage: "checkmark.circle").foregroundStyle(.green)
        case false?:
            Label("Wake for network access is off", systemImage: "moon.zzz").foregroundStyle(.orange)
            Text("To reach this Mac while it sleeps, turn on System Settings → Energy (or Battery → Options) → "
                 + "Wake for network access. On a headless Mac mini, also set it to start up after a power failure. "
                 + "ClawTank keeps the Mac awake during a session.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Energy Settings") { open("x-apple.systempreferences:com.apple.Battery-Settings.extension") }
        case nil:
            Text("Couldn't read the wake setting.").foregroundStyle(.secondary)
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
