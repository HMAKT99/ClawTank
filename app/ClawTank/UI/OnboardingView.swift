// First-run setup: what ClawTank does → Screen Recording → Accessibility → password → how to
// connect. Permission steps watch the grant live, so the user never has to come back and click
// "check again".

import ApplicationServices
import SwiftUI

struct OnboardingView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var settings: AppSettings
    let onDone: () -> Void

    enum Step: Int, CaseIterable { case welcome, screen, accessibility, password, done }

    @State private var step: Step = .welcome
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var accessibilityGranted = AXIsProcessTrusted()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ProgressView(value: Double(step.rawValue), total: Double(Step.allCases.count - 1))
                .accessibilityLabel("Setup progress")
            content
            Spacer(minLength: 0)
            HStack {
                if step != .welcome && step != .done {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                primaryButton
            }
        }
        .padding(28)
        .frame(minWidth: 560, minHeight: 460)
        .onReceive(poll) { _ in
            screenGranted = CGPreflightScreenCaptureAccess()
            accessibilityGranted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            Header(title: "Welcome to ClawTank", symbol: "display")
            Text("ClawTank lets you reach this Mac from any standard Remote Desktop client — Windows, " +
                 "Mac, iPad, iPhone or Linux — with a crisp, fast, full desktop. It works only on your " +
                 "local network unless you change that, and nothing goes through any cloud.")
            Text("Setup takes about a minute: two macOS permissions and a password.")
                .foregroundStyle(.secondary)
        case .screen:
            Header(title: "Allow Screen Recording", symbol: "rectangle.dashed.badge.record")
            Text("ClawTank needs to see the screen to send it to your remote client. Click the button, " +
                 "turn on ClawTank in the list, and come back.")
            PermissionRow(granted: screenGranted, action: "Open Screen Recording Settings") {
                CGRequestScreenCaptureAccess()
                open("Privacy_ScreenCapture")
            }
            if !screenGranted {
                Text("If macOS asks to quit and reopen ClawTank, choose Quit & Reopen; setup continues.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        case .accessibility:
            Header(title: "Allow Accessibility", symbol: "keyboard")
            Text("To type and click for you, ClawTank needs Accessibility. Turn on ClawTank in the list.")
            PermissionRow(granted: accessibilityGranted, action: "Open Accessibility Settings") {
                let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                open("Privacy_Accessibility")
            }
        case .password:
            Header(title: "Choose a Password", symbol: "lock")
            Text("Your Remote Desktop client will ask for this, with the username **\(server.username)**. " +
                 "It's separate from your Mac's login password.")
            PasswordChanger(server: server, finishTitle: "Save Password") { step = .done }
            Button("Keep the generated password") { step = .done }
                .buttonStyle(.link)
        case .done:
            Header(title: "You're Ready", symbol: "checkmark.seal")
            ConnectionDetails(server: server)
            Divider()
            ConnectGuide(address: server.address, username: server.username,
                         remoteAddress: server.remote.remoteAddress)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch step {
        case .welcome: Button("Get Started") { step = .screen }.keyboardShortcut(.defaultAction)
        case .screen: Button(screenGranted ? "Continue" : "Skip for Now") { step = .accessibility }
            .keyboardShortcut(.defaultAction)
        case .accessibility: Button(accessibilityGranted ? "Continue" : "Skip for Now") { step = .password }
            .keyboardShortcut(.defaultAction)
        case .password: EmptyView()
        case .done:
            Button("Done") {
                settings.hasCompletedOnboarding = true
                onDone()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct Header: View {
    let title: String
    let symbol: String
    var body: some View {
        Label(title, systemImage: symbol)
            .font(.title.bold())
            .accessibilityAddTraits(.isHeader)
    }
}

private struct PermissionRow: View {
    let granted: Bool
    let action: String
    let open: () -> Void
    var body: some View {
        HStack {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(action, action: open)
                Label("Waiting…", systemImage: "hourglass").foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Address, username, password and fingerprint with copy buttons.
struct ConnectionDetails: View {
    @ObservedObject var server: ServerController
    @State private var revealed = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Address", server.address) { server.copyAddress() }
            row("Username", server.username) { copy(server.username) }
            row("Password", revealed ? server.password : String(repeating: "•", count: 12)) { server.copyPassword() }
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Toggle("Show password", isOn: $revealed).toggleStyle(.checkbox)
            }
            row("Certificate", String(server.fingerprint.prefix(47)) + "…") { server.copyFingerprint() }
        }
    }

    private func row(_ label: String, _ value: String, copy: @escaping () -> Void) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).font(.body.monospaced())
            Button("Copy", action: copy).accessibilityLabel("Copy \(label)")
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// New-password field with live policy feedback.
struct PasswordChanger: View {
    @ObservedObject var server: ServerController
    let finishTitle: String
    let onSaved: () -> Void
    @State private var first = ""
    @State private var second = ""
    @State private var saved = false

    private var problems: [PasswordPolicy.Problem] { PasswordPolicy.problems(first, username: server.username) }
    private var mismatch: Bool { !second.isEmpty && first != second }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("New password", text: $first).textContentType(.newPassword)
            SecureField("Repeat password", text: $second).textContentType(.newPassword)
            if !first.isEmpty {
                ForEach(problems, id: \.self) { problem in
                    Label(PasswordPolicy.message(for: problem), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
            }
            if mismatch {
                Label("The passwords don't match.", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            }
            HStack {
                Button(finishTitle) {
                    if server.setPassword(first).isEmpty {
                        saved = true
                        first = ""
                        second = ""
                        onSaved()
                    }
                }
                .disabled(first.isEmpty || !problems.isEmpty || first != second)
                if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.green) }
            }
        }
    }
}
