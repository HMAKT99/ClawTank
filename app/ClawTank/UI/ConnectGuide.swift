// "How to connect" instructions per client platform, shared by onboarding and Settings.

import SwiftUI

struct ConnectGuide: View {
    let address: String
    let username: String
    /// Tailscale name/IP, if this Mac is on a tailnet.
    var remoteAddress: String?

    enum Platform: String, CaseIterable, Identifiable {
        case windows = "Windows", mac = "Mac", mobile = "iPad / iPhone", linux = "Linux", away = "From anywhere"
        var id: String { rawValue }
    }

    @State private var platform: Platform = .mac

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Connect from", selection: $platform) {
                ForEach(Platform.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(steps(for: platform))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func steps(for platform: Platform) -> String {
        switch platform {
        case .windows:
            """
            1. Open Remote Desktop Connection (press Win+R, type mstsc, Enter).
            2. Computer: \(address). Click Show Options; User name: \(username).
            3. Connect, enter your ClawTank password, and accept the certificate after checking \
            its fingerprint matches the one shown in ClawTank.
            """
        case .mac:
            """
            1. Install Windows App from the Mac App Store.
            2. Click + → Add PC. PC name: \(address). User account: add \(username) and your ClawTank \
            password.
            3. Double-click the PC. Tip: in the PC's settings, turn on "Optimize for Retina displays" \
            for crisp text.
            """
        case .mobile:
            """
            1. Install Windows App from the App Store.
            2. Tap + → Add PC. PC name: \(address). User account: \(username) and your ClawTank password.
            3. Tap the PC to connect.
            """
        case .linux:
            """
            Using FreeRDP 3:
            xfreerdp3 /v:\(address) /u:\(username) /dynamic-resolution /gfx:avc420
            Or add an RDP connection in Remmina with the same address and username.
            """
        case .away:
            if let remoteAddress {
                """
                This Mac is on Tailscale. On the other device, install Tailscale, sign in to the same \
                account, then use \(remoteAddress) as the PC name (same username and password). \
                Nothing is opened to the internet: the connection travels inside Tailscale's encrypted network.
                """
            } else {
                """
                To connect from outside your home or office, install Tailscale (free for personal use) on \
                this Mac and on the device you connect from, and sign in to the same account on both. \
                Then use this Mac's Tailscale name as the PC name. See Settings → Remote Access. \
                Don't forward port 3389 on your router.
                """
            }
        }
    }
}
