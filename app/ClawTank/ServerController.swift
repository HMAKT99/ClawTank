// Owns the RDP server's lifecycle for the app and publishes its state to the UI.
// Core events arrive on a Rust thread and are applied on the main actor; every connection
// attempt is written to the audit log, and the Mac is kept awake while a client is connected.

import AppKit
import ApplicationServices
import ClawTankCore
import Combine
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

    struct SessionInfo: Equatable {
        let peer: String
        let since: Date
        var resolution: String?
    }

    @Published private(set) var status: Status = .stopped
    /// Most recent noteworthy event (failed login, refused peer), shown in the menu.
    @Published private(set) var lastNotice: String?
    @Published private(set) var fingerprint = ""
    /// The connected client, if any.
    @Published private(set) var session: SessionInfo?
    /// Live video readout, e.g. "60 fps · 14.2 Mbit/s · enc 3.1 ms"; nil when not streaming.
    @Published private(set) var videoStatus: String?
    /// e.g. "Virtual display 1512×982" while streaming.
    @Published private(set) var displayDescription: String?
    /// Tailscale status: how (and whether) this Mac can be reached from outside the LAN.
    @Published private(set) var remote: TailscaleState = .notInstalled
    @Published private(set) var wakeForNetwork: Bool?
    /// File transfer progress, e.g. "Receiving files: 40% of 1.2 GB".
    @Published private(set) var transferStatus: String?
    /// The Mac's screen is locked: a remote user sees only the wallpaper (macOS hides the lock
    /// screen from capture and blocks synthetic input there; see ADR-018).
    @Published private(set) var screenLocked = false

    let settings: AppSettings
    let audit: AuditLog
    let username: String
    let hostName: String

    private let security: SecurityService
    private let power: PowerManaging
    private(set) var password = ""
    private var server: RdpServer?
    private var video: VideoSession?
    private var videoTask: Task<Void, Never>?
    private let displays = DisplayService()
    private var statsTimer: Timer?
    private var lastCounters = VideoSession.Counters()
    private let overlayFlag = AtomicFlag()
    private let input: InputPipeline
    private var cursor: CursorPublisher?
    private var media: SessionMedia?
    /// Answers file-contents requests on its own queue, straight from the core's thread.
    private let fileServer = FileServer()
    private var subscriptions: Set<AnyCancellable> = []
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "server")

    init(settings: AppSettings, security: SecurityService = SecurityService(), audit: AuditLog = AuditLog(),
         power: PowerManaging = PowerAssertions()) {
        self.settings = settings
        self.security = security
        self.audit = audit
        self.power = power
        self.username = security.username
        self.hostName = Self.localHostName()
        self.input = InputPipeline(swapControlCommand: settings.swapControlCommand)
        overlayFlag.set(settings.showsStatsOverlay)
        settings.$showsStatsOverlay.sink { [overlayFlag] in overlayFlag.set($0) }.store(in: &subscriptions)
        settings.$swapControlCommand.sink { [input] in input.setSwapControlCommand($0) }.store(in: &subscriptions)
        let center = DistributedNotificationCenter.default()
        center.publisher(for: Notification.Name("com.apple.screenIsLocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setScreenLocked(true) }.store(in: &subscriptions)
        center.publisher(for: Notification.Name("com.apple.screenIsUnlocked"))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setScreenLocked(false) }.store(in: &subscriptions)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect().prepend(Date())
            .sink { [weak self] _ in self?.refreshRemoteAccess() }.store(in: &subscriptions)
        settings.$keepAwake.sink { [weak self] keep in
            guard let self, session != nil else { return }
            if keep { _ = power.begin(reason: "ClawTank remote session") } else { power.end() }
        }.store(in: &subscriptions)
    }

    var isRunning: Bool { server != nil }
    var port: UInt16 { UInt16(clamping: settings.port) }
    var address: String { port == 3389 ? hostName : "\(hostName):\(port)" }

    func start() {
        guard server == nil else { return }
        do {
            let identity = try security.loadOrCreateIdentity(commonName: hostName)
            password = try security.loadOrCreatePassword()
            fingerprint = identity.fingerprint
            let configuration = RdpServer.Configuration(
                port: port, username: username, password: password, identity: identity,
                lanOnly: settings.lanOnly, allowlist: settings.allowlist)
            let input = self.input
            let fileServer = self.fileServer
            let created = try RdpServer(configuration: configuration, onEvent: { [weak self] event in
                // Hot path during file copies: answer on the file queue, not the main thread.
                if case .clipboardFileRequested(let stream, let index, let query) = event {
                    fileServer.serve(stream: stream, index: index, query: query)
                    return
                }
                Task { @MainActor in self?.handle(event) }
            }, onInput: { input.handle($0) })
            fileServer.attach(created)
            server = created
            status = .listening(port: server?.port ?? port)
            lastNotice = nil
            log.info("Server started on port \(self.port) lanOnly=\(self.settings.lanOnly)")
        } catch RdpServer.StartError.failed(let code) where code == CT_STATUS_BIND_FAILED.rawValue {
            fail("Port \(port) is in use or unavailable")
        } catch RdpServer.StartError.failed(let code) where code == CT_STATUS_INVALID_ARGUMENT.rawValue {
            fail("Invalid allowlist (use IPs or CIDRs like 192.168.1.0/24)")
        } catch {
            fail("Could not start: \(error)")
        }
    }

    func stop() {
        endSession()
        server?.stop()
        server = nil
        status = .stopped
    }

    /// Applies changed network settings (port, LAN-only, allowlist).
    func restart() {
        stop()
        start()
    }

    /// Ends the current client's session; the server keeps listening.
    func disconnectClient() {
        _ = server?.disconnectClient()
    }

    /// Validates and sets a new RDP password. Returns the problems if it was rejected.
    func setPassword(_ newPassword: String) -> [PasswordPolicy.Problem] {
        let problems = PasswordPolicy.problems(newPassword, username: username)
        guard problems.isEmpty else { return problems }
        do {
            try security.setPassword(newPassword)
            password = newPassword
            if let server, !server.setCredentials(username: username, password: newPassword) {
                log.error("Core rejected new credentials")
            }
            log.info("RDP password changed")
        } catch {
            lastNotice = "Couldn't save the password: \(error.localizedDescription)"
        }
        return []
    }

    // MARK: - Events

    private func handle(_ event: RdpServer.Event) {
        guard server != nil else { return }
        switch event {
        case .videoStart(let width, let height):
            startVideo(width: width, height: height, scalePercent: nil)
        case .videoResize(let width, let height, let scale):
            startVideo(width: width, height: height, scalePercent: scale)
        case .videoStop:
            stopVideo()
        case .audioStart, .audioStop, .clipboardReady, .clipboardRemoteFormats, .clipboardDataRequested,
             .clipboardData, .clipboardRemoteFiles, .clipboardFileRequested, .clipboardFileContents:
            if let media { media.handle(event) } else if case .clipboardDataRequested = event {
                server?.clipboardProvide(nil)
            }
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
            beginSession(peer: Self.ipOnly(peer))
        case .clientDisconnected(let peer, let error):
            record(.disconnected, Self.ipOnly(peer), detail: error)
            endSession()
            status = .listening(port: server?.port ?? port)
        case .connectionFailed, .rejected, .lockedOut:
            handleAccessEvent(event)
        case .error(let message):
            fail(message)
        case .stopped:
            if case .failed = status { return }
            status = .stopped
        default:
            break
        }
    }

    /// Failed logins, refusals and lockouts: shown in the menu and written to the audit log.
    private func handleAccessEvent(_ event: RdpServer.Event) {
        switch event {
        case .connectionFailed(let peer, let error):
            let ip = Self.ipOnly(peer)
            log.notice("Connection from \(ip, privacy: .public) failed: \(error, privacy: .public)")
            lastNotice = "Failed login from \(ip)"
            record(.failedLogin, ip, detail: error)
        case .rejected(let peer, let reason):
            let ip = Self.ipOnly(peer)
            lastNotice = Self.describeRefusal(reason, ip: ip)
            record(.refused, ip, detail: reason)
        case .lockedOut(let ip, let minutes):
            lastNotice = "Locked out \(ip) for \(minutes) min after repeated failed logins"
            record(.lockedOut, ip, detail: "\(minutes) min")
        default:
            break
        }
    }

    private func record(_ outcome: AuditEntry.Outcome, _ ip: String, detail: String? = nil) {
        // Only sessions prove which account was used; the core never learns the username of a
        // failed attempt, so don't imply one.
        let user: String? = outcome == .connected || outcome == .disconnected ? username : nil
        audit.append(AuditEntry(time: Date(), peer: ip, user: user, outcome: outcome,
                                detail: detail.map(Self.friendlyDetail)))
    }

    private func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        log.notice("Screen \(locked ? "locked" : "unlocked", privacy: .public)")
    }

    private func beginSession(peer ip: String) {
        status = .connected(peer: ip)
        session = SessionInfo(peer: ip, since: Date())
        lastNotice = nil
        record(.connected, ip)
        if settings.keepAwake { _ = power.begin(reason: "ClawTank remote session") }
        startInput()
        if let server {
            media = SessionMedia(server: server, settings: settings, fileServer: fileServer) { [weak self] in
                self?.transferStatus = $0
            }
        }
    }

    private func endSession() {
        media?.stop()
        media = nil
        stopInput()
        stopVideo(releaseDisplay: true)
        power.end()
        session = nil
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

    private func fail(_ message: String) {
        log.error("\(message, privacy: .public)")
        endSession()
        server?.stop()
        server = nil
        status = .failed(message)
    }

}

// Video lifecycle (same file, so it keeps access to the controller's private state).
extension ServerController {
    /// Starts (or, after a resize, restarts) video at `width`×`height`. Start, stop and restart
    /// run strictly in order on `videoTask` so a resize can't race a disconnect.
    private func startVideo(width: Int, height: Int, scalePercent: Int?) {
        guard server != nil else { return }
        guard CGPreflightScreenCaptureAccess() else {
            // Shows the system prompt the first time; afterwards the user must use Settings.
            CGRequestScreenCaptureAccess()
            lastNotice = "Grant Screen Recording to ClawTank in System Settings, then reconnect"
            log.notice("Screen Recording not granted; client sees the test pattern")
            return
        }
        let mode = settings.displayMode
        let frameRate = settings.frameRate
        let bitRateFactor = settings.quality.bitRateFactor
        enqueueVideo { [self] in
            await stopCurrentVideo()
            guard let server else { return }
            guard let target = await displays.prepare(width: width, height: height,
                                                      scalePercent: scalePercent, mode: mode) else {
                lastNotice = "No display available to share"
                return
            }
            input.setSession(width: width, height: height, displayBounds: target.bounds)
            let flag = overlayFlag
            let video = VideoSession(server: server, width: width, height: height, target: target,
                                     frameRate: frameRate, bitRateFactor: bitRateFactor) { flag.get() }
            self.video = video
            lastCounters = .init()
            do {
                try await video.start()
                displayDescription = "\(target.isVirtual ? "Virtual" : "Physical") display \(width)×\(height)"
                session?.resolution = "\(width)×\(height)"
                log.info("Video \(width)x\(height)@\(frameRate) on \(target.displayID) virtual=\(target.isVirtual)")
            } catch {
                log.error("Video start failed: \(error.localizedDescription, privacy: .public)")
                if self.video === video { self.video = nil }
                lastNotice = "Video failed: \(error.localizedDescription)"
                return
            }
            statsTimer?.invalidate()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateVideoStats() }
            }
        }
    }

    /// Stops video; with `releaseDisplay` also removes the virtual display (session over).
    private func stopVideo(releaseDisplay: Bool = false) {
        enqueueVideo { [self] in
            await stopCurrentVideo()
            if releaseDisplay {
                displays.release()
                displayDescription = nil
            }
        }
    }

    private func enqueueVideo(_ operation: @escaping @MainActor () async -> Void) {
        let previous = videoTask
        videoTask = Task { @MainActor in
            await previous?.value
            await operation()
        }
    }

    private func stopCurrentVideo() async {
        statsTimer?.invalidate()
        statsTimer = nil
        videoStatus = nil
        guard let video else { return }
        self.video = nil
        await video.stop()
    }

    private func updateVideoStats() {
        guard let video else { return }
        let now = video.snapshot()
        let encoded = now.encodedFrames - lastCounters.encodedFrames
        let bytes = now.sentBytes - lastCounters.sentBytes
        let encodeTime = now.encodeSeconds - lastCounters.encodeSeconds
        let skipped = now.skippedFrames - lastCounters.skippedFrames
        lastCounters = now
        var text = Self.formatVideoStats(fps: encoded, bytesPerSecond: bytes,
                                         encodeMs: encoded > 0 ? encodeTime * 1000 / Double(encoded) : 0,
                                         skipped: skipped)
        if let core = server?.videoStats {
            let sample = AdaptiveBitrate.Sample(skippedFrames: skipped, framesInFlight: Int(core.frames_in_flight),
                                                ackLatencyMs: Double(core.ack_latency_us) / 1000,
                                                framesSent: encoded)
            if let (rate, congested) = video.adapt(sample) {
                text += String(format: " · rtt %.0f ms · target %.1f Mbit/s%@", sample.ackLatencyMs,
                               Double(rate) / 1_000_000, congested ? " (congested)" : "")
            }
        }
        videoStatus = text
        video.setOverlayText(text)
    }
}

// MARK: - Remote access (Tailscale)

extension ServerController {
    /// Re-detects Tailscale and the wake setting (runs the CLI off the main thread).
    func refreshRemoteAccess() {
        Task.detached(priority: .utility) {
            let state = RemoteAccess.detect()
            let wake = RemoteAccess.wakeForNetworkAccess()
            await MainActor.run { [weak self] in
                self?.remote = state
                self?.wakeForNetwork = wake
            }
        }
    }

    func copyRemoteAddress() {
        if let address = remote.remoteAddress { Self.copyToPasteboard(address) }
    }
}
