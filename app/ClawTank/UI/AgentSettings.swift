// Settings → Agents: turn the local Agent API on, create and revoke per-agent tokens, and copy
// the MCP setup command. A token is shown once, right after it's created.

import SwiftUI

struct AgentSettings: View {
    @ObservedObject var agents: AgentService
    @ObservedObject var settings: AppSettings
    @State private var newName = ""
    @State private var newSecret: String?

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to control this Mac", isOn: $settings.agentAPIEnabled)
                Text("Agents on this Mac can take screenshots, move the mouse, type and open apps through a local "
                     + "API (127.0.0.1 only, never the network). Each agent needs its own token. Every action is "
                     + "written to the connection log, a badge shows while an agent is in control, and a person "
                     + "using the Mac over RDP always takes priority.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                LabeledContent("Status", value: statusText)
                TextField("Port", value: $settings.agentPort, format: .number.grouping(.never))
                    .disabled(settings.agentAPIEnabled)
            }
            Section("Tokens") {
                if agents.tokens.isEmpty { Text("No tokens yet.").foregroundStyle(.secondary) }
                ForEach(agents.tokens) { token in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(token.name)
                            Text(detail(token)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) { agents.revoke(token) }
                    }
                }
                HStack {
                    TextField("Agent name, e.g. Claude Code", text: $newName)
                    Button("Create Token") {
                        newSecret = agents.createToken(name: newName)
                        newName = ""
                    }
                }
                if let newSecret {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Copy this token now; it won't be shown again.").font(.callout.weight(.medium))
                        HStack {
                            Text(newSecret).font(.body.monospaced()).textSelection(.enabled).lineLimit(1)
                            Button("Copy") { ServerController.copyToPasteboard(newSecret) }
                        }
                    }
                }
            }
            Section("Connect an MCP agent") {
                Text("For Claude Code (other MCP clients: run the same binary over stdio with the token in "
                     + "CLAWTANK_AGENT_TOKEN):").font(.callout)
                Text(agents.setupCommand).font(.caption.monospaced()).textSelection(.enabled)
                Button("Copy Command") {
                    ServerController.copyToPasteboard(agents.setupCommand.replacingOccurrences(
                        of: "<token>", with: newSecret ?? "<token>"))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var statusText: String {
        switch agents.status {
        case .off: "Off"
        case .listening(let port): "Listening on 127.0.0.1:\(port)"
        case .failed(let message): "Couldn't start: \(message)"
        }
    }

    private func detail(_ token: AgentToken) -> String {
        let created = "Created " + token.created.formatted(date: .abbreviated, time: .shortened)
        return created + (token.lastUsed.map { " · last used " + $0.formatted(.relative(presentation: .named)) } ?? "")
    }
}
