// Runs the Agent API while it's enabled in Settings (off by default), records every agent
// request in the audit log, and shows who is in control: the menu-bar icon, a menu line and a
// floating "Agent in control" badge with a Stop button (ADR-023).

import AppKit
import Combine
import Foundation
import Network
import os

@MainActor
final class AgentService: ObservableObject {
    enum ListenerStatus: Equatable {
        case off
        case listening(port: Int)
        case failed(String)
    }

    @Published private(set) var tokens: [AgentToken]
    /// The agent that acted in the last few seconds, if any.
    @Published private(set) var activeAgent: String?
    @Published private(set) var lastAction: String?
    @Published private(set) var status: ListenerStatus = .off

    static let activeWindow: TimeInterval = 10

    private let settings: AppSettings
    private let audit: AuditLog
    private let store: AgentTokenStore
    private let host = MacAgentHost()
    private let human: HumanActivity
    private var server: HTTPServer?
    private var lastActionAt = Date.distantPast
    private var subscriptions: Set<AnyCancellable> = []
    private lazy var indicator = AgentIndicator { [weak self] in self?.stopAgents() }
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "agent")

    init(settings: AppSettings, audit: AuditLog, human: HumanActivity, store: AgentTokenStore = AgentTokenStore()) {
        self.settings = settings
        self.audit = audit
        self.human = human
        self.store = store
        tokens = store.all
    }

    /// Starts following the Settings toggle and port.
    func activate() {
        settings.$agentAPIEnabled.combineLatest(settings.$agentPort)
            .removeDuplicates { $0 == $1 }
            .sink { [weak self] enabled, port in self?.apply(enabled: enabled, port: port) }
            .store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.expireActivity() }.store(in: &subscriptions)
    }

    var setupCommand: String {
        let binary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/clawtank-mcp").path
        let url = settings.agentPort == 3390 ? "" : " --env CLAWTANK_AGENT_URL=http://127.0.0.1:\(settings.agentPort)"
        return "claude mcp add clawtank --env CLAWTANK_AGENT_TOKEN=<token>\(url) -- \"\(binary)\""
    }

    func createToken(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let (token, secret) = store.create(name: trimmed.isEmpty ? "Agent" : String(trimmed.prefix(40)))
        tokens = store.all
        audit.append(AuditEntry(time: Date(), peer: "Agent API", user: token.name, outcome: .agentAction,
                                detail: "token created"))
        return secret
    }

    func revoke(_ token: AgentToken) {
        store.revoke(id: token.id)
        tokens = store.all
        audit.append(AuditEntry(time: Date(), peer: "Agent API", user: token.name, outcome: .agentAction,
                                detail: "token revoked"))
    }

    /// The person pressed Stop: turn the API off (also removes agent-created virtual displays).
    func stopAgents() {
        settings.agentAPIEnabled = false
    }

    private func apply(enabled: Bool, port: Int) {
        server?.stop()
        server = nil
        if !enabled {
            host.removeAllVirtualDisplays()
            status = .off
            clearActivity()
            return
        }
        let audit = audit
        let onEvent: @Sendable (AgentEvent) -> Void = { [weak self] event in
            audit.append(AuditEntry(time: Date(), peer: "Agent API", user: event.agent,
                                    outcome: event.allowed ? .agentAction : .agentRefused,
                                    detail: event.action + (event.detail.map { " — \($0)" } ?? "")))
            Task { @MainActor in self?.noteActivity(event) }
        }
        let api = AgentAPI(host: host, tokens: store, human: human, port: { port }, onEvent: onEvent)
        do {
            let created = try HTTPServer(port: UInt16(port)) { await api.handle($0) }
            created.start { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state, port: port) }
            }
            server = created
        } catch {
            status = .failed("\(error)")
        }
    }

    private func listenerChanged(_ state: NWListener.State, port: Int) {
        switch state {
        case .ready: status = .listening(port: port)
        case .failed(let error):
            log.error("agent API listener failed: \(String(describing: error), privacy: .public)")
            status = .failed(error.debugDescription)
        default: break
        }
    }

    private func noteActivity(_ event: AgentEvent) {
        guard event.allowed, event.agent != "(unknown)" else { return }
        lastActionAt = Date()
        lastAction = event.action
        if activeAgent != event.agent {
            activeAgent = event.agent
            indicator.show(agent: event.agent)
        }
    }

    private func expireActivity() {
        if activeAgent != nil, Date().timeIntervalSince(lastActionAt) > Self.activeWindow { clearActivity() }
    }

    private func clearActivity() {
        activeAgent = nil
        indicator.hide()
    }
}
