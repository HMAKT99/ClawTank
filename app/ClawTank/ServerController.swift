// Owns the RDP server's lifecycle for the app and publishes its state to the menu.
// Core events arrive on a Rust thread and are applied on the main actor.

import AppKit
import ApplicationServices
import ClawTankCore
import Foundation
import os
import SystemConfiguration

/// A Bool readable from any thread (the overlay toggle is read on the capture queue).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

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
    /// Live video readout, e.g. "60 fps · 14.2 Mbit/s · enc 3.1 ms"; nil when not streaming.
    @Published private(set) var videoStatus: String?
    @Published var showsStatsOverlay = false {
        didSet { overlayFlag.set(showsStatsOverlay) }
    }
    /// Ctrl ↔ ⌘ swap for clients whose users press Ctrl+C to copy (persisted).
    @Published var swapControlCommand = UserDefaults.standard.bool(forKey: "swapControlCommand") {
        didSet {
            UserDefaults.standard.set(swapControlCommand, forKey: "swapControlCommand")
            input.setSwapControlCommand(swapControlCommand)
        }
    }

    let username: String
    let hostName: String

    private let security: SecurityService
    private let port: UInt16
    private var password = ""
    private var server: RdpServer?
    private var video: VideoSession?
    private var statsTimer: Timer?
    private var lastCounters = VideoSession.Counters()
    private let overlayFlag = AtomicFlag()
    private let input = InputPipeline(swapControlCommand: UserDefaults.standard.bool(forKey: "swapControlCommand"))
    private var cursor: CursorPublisher?
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
            let input = self.input
            server = try RdpServer(configuration: configuration, onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }, onInput: { input.handle($0) })
            status = .listening(port: server?.port ?? port)
            log.info("Server started on port \(self.port)")
        } catch RdpServer.StartError.failed(let code) where code == CT_STATUS_BIND_FAILED.rawValue {
            fail("Port \(port) is in use or unavailable")
        } catch {
            fail("Could not start: \(error)")
        }
    }

    func stop() {
        stopInput()
        stopVideo()
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
        case .videoStart(let width, let height):
            startVideo(width: width, height: height)
        case .videoStop:
            stopVideo()
        default:
            handleConnection(event)
        }
    }

    private func handleConnection(_ event: RdpServer.Event) {
        switch event {
        case .listening:
            if case .connected = status { return }
            status = .listening(port: server?.port ?? port)
        case .clientConnected(let peer):
            status = .connected(peer: Self.ipOnly(peer))
            lastNotice = nil
            startInput()
        case .clientDisconnected:
            stopInput()
            stopVideo()
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
        case .videoStart, .videoStop:
            break
        }
    }

    // MARK: - Input and cursor

    private func startInput() {
        // Shows the system prompt the first time; input is ignored until granted.
        // "AXTrustedCheckOptionPrompt" is the value of kAXTrustedCheckOptionPrompt (a C global).
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            lastNotice = "Grant Accessibility to ClawTank in System Settings to enable keyboard and mouse"
            log.notice("Accessibility not granted; input is ignored")
        }
        guard let server, cursor == nil else { return }
        let input = self.input
        let publisher = CursorPublisher(scale: { input.currentScale() }, send: { server.setPointer($0) })
        publisher.start()
        cursor = publisher
    }

    private func stopInput() {
        input.releaseAll()
        cursor?.stop()
        cursor = nil
    }

    // MARK: - Video

    private func startVideo(width: Int, height: Int) {
        guard let server, video == nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; afterwards the user must use Settings.
            CGRequestScreenCaptureAccess()
            lastNotice = "Grant Screen Recording to ClawTank in System Settings, then reconnect"
            log.notice("Screen Recording not granted; client sees the test pattern")
            return
        }
        input.setSession(width: width, height: height)
        let flag = overlayFlag
        let session = VideoSession(server: server, width: width, height: height) { flag.get() }
        video = session
        lastCounters = .init()
        Task {
            do {
                try await session.start()
                log.info("Video started \(width)x\(height), hardware=\(session.isHardwareAccelerated)")
            } catch {
                log.error("Video start failed: \(error.localizedDescription, privacy: .public)")
                if video === session { video = nil }
                lastNotice = "Video failed: \(error.localizedDescription)"
            }
        }
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateVideoStats() }
        }
    }

    private func stopVideo() {
        statsTimer?.invalidate()
        statsTimer = nil
        videoStatus = nil
        guard let session = video else { return }
        video = nil
        Task { await session.stop() }
    }

    private func updateVideoStats() {
        guard let session = video else { return }
        let now = session.snapshot()
        let encoded = now.encodedFrames - lastCounters.encodedFrames
        let bytes = now.sentBytes - lastCounters.sentBytes
        let encodeTime = now.encodeSeconds - lastCounters.encodeSeconds
        let skipped = now.skippedFrames - lastCounters.skippedFrames
        lastCounters = now
        let text = Self.formatVideoStats(fps: encoded, bytesPerSecond: bytes,
                                         encodeMs: encoded > 0 ? encodeTime * 1000 / Double(encoded) : 0,
                                         skipped: skipped)
        videoStatus = text
        session.setOverlayText(text)
        log.debug("video \(text, privacy: .public)")
    }

    nonisolated static func formatVideoStats(fps: Int, bytesPerSecond: Int, encodeMs: Double, skipped: Int) -> String {
        let mbit = Double(bytesPerSecond * 8) / 1_000_000
        var text = String(format: "%d fps · %.1f Mbit/s · enc %.1f ms", fps, mbit, encodeMs)
        if skipped > 0 { text += " · \(skipped) skipped" }
        return text
    }

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        stopVideo()
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
