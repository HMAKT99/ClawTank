// Owns the RDP server's lifecycle for the app and publishes its state to the menu.
// Core events arrive on a Rust thread and are applied on the main actor.

import AppKit
import ClawTankCore
import Foundation
import os
import SystemConfiguration

@MainActor
final class ServerController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case listening(port: UInt16)
        case connected(peer: String)
        case failed(String)
    }

    static let defaultPort: UInt16 = 3389

    @Published private(set) var status: Status = .stopped
    /// Most recent noteworthy event (failed login, rejected peer), shown in the menu.
    @Published private(set) var lastNotice: String?
    @Published private(set) var fingerprint = ""

    let username: String
    let hostName: String

    private let security: SecurityService
    private let port: UInt16
    private var password = ""
    private var server: RdpServer?
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "server")

    init(security: SecurityService = SecurityService(), port: UInt16 = ServerController.defaultPort) {
        self.security = security
        self.port = port
        self.username = security.username
        self.hostName = Self.localHostName()
    }

    var isRunning: Bool { server != nil }

    func start() {
        guard server == nil else { return }
        do {
            let identity = try security.loadOrCreateIdentity(commonName: hostName)
            password = try security.loadOrCreatePassword()
            fingerprint = identity.fingerprint
            let configuration = RdpServer.Configuration(
                port: port, username: username, password: password, identity: identity)
            server = try RdpServer(configuration: configuration) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            status = .listening(port: server?.port ?? port)
            log.info("Server started on port \(self.port)")
        } catch RdpServer.StartError.failed(let code) where code == CT_STATUS_BIND_FAILED.rawValue {
            fail("Port \(port) is in use or unavailable")
        } catch {
            fail("Could not start: \(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    func copyPassword() {
        copyToPasteboard(password)
    }

    func copyFingerprint() {
        copyToPasteboard(fingerprint)
    }

    func copyAddress() {
        copyToPasteboard(port == 3389 ? hostName : "\(hostName):\(port)")
    }

    private func handle(_ event: RdpServer.Event) {
        guard server != nil else { return }
        switch event {
        case .listening:
            if case .connected = status { return }
            status = .listening(port: server?.port ?? port)
        case .clientConnected(let peer):
            status = .connected(peer: Self.ipOnly(peer))
            lastNotice = nil
        case .clientDisconnected:
            status = .listening(port: server?.port ?? port)
        case .connectionFailed(let peer, let error):
            log.notice("Connection from \(peer, privacy: .public) failed: \(error, privacy: .public)")
            lastNotice = "Failed login from \(Self.ipOnly(peer))"
        case .rejected(let peer):
            lastNotice = "Blocked non-LAN connection from \(Self.ipOnly(peer))"
        case .error(let message):
            fail(message)
        case .stopped:
            if case .failed = status { return }
            status = .stopped
        }
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        server?.stop()
        server = nil
        status = .failed(message)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// "192.168.1.5:51234" → "192.168.1.5"; "[fe80::1]:5" → "fe80::1".
    nonisolated static func ipOnly(_ peer: String) -> String {
        if peer.hasPrefix("["), let end = peer.firstIndex(of: "]") {
            return String(peer[peer.index(after: peer.startIndex)..<end])
        }
        guard let colon = peer.lastIndex(of: ":") else { return peer }
        return String(peer[..<colon])
    }

    /// The Bonjour name clients can use, e.g. "macmini.local".
    nonisolated static func localHostName() -> String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? {
            return "\(name).local"
        }
        return ProcessInfo.processInfo.hostName
    }
}
