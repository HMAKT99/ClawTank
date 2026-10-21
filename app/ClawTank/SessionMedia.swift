// Per-session audio and clipboard: created when a client connects (honouring the audio and
// clipboard settings at that moment) and stopped when it leaves.

import Foundation
import os

@MainActor
final class SessionMedia {
    private let server: RdpServer
    private let settings: AppSettings
    private var clipboard: ClipboardService?
    private var audio: AudioCapture?
    private let localMute = LocalMute()
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "media")

    init(server: RdpServer, settings: AppSettings, fileServer: FileServer? = nil,
         onTransferStatus: @escaping (String?) -> Void = { _ in }) {
        self.server = server
        self.settings = settings
        if settings.clipboardEnabled {
            let service = ClipboardService(server: server, fileServer: fileServer)
            service.onTransferStatus = onTransferStatus
            service.start()
            clipboard = service
        }
    }

    func handle(_ event: RdpServer.Event) {
        switch event {
        case .audioStart(let rate, let channels): startAudio(rate: rate, channels: channels)
        case .audioStop: stopAudio()
        default: handleClipboard(event)
        }
    }

    private func handleClipboard(_ event: RdpServer.Event) {
        switch event {
        case .clipboardReady: clipboard?.channelReady()
        case .clipboardRemoteFormats(let formats): clipboard?.remoteCopied(formats)
        case .clipboardDataRequested(let format):
            if let clipboard { clipboard.dataRequested(format) } else { server.clipboardProvide(nil) }
        case .clipboardData: clipboard?.remoteDataArrived()
        case .clipboardRemoteFiles(let files): clipboard?.remoteFilesListed(files)
        case .clipboardFileContents(let stream): clipboard?.fileContentsArrived(stream: stream)
        case .clipboardFileRequested(let stream, let index, let query):
            if let clipboard {
                clipboard.fileRequested(stream: stream, index: index, query: query)
            } else {
                server.clipboardAnswerFile(stream: stream, .error)
            }
        default: break
        }
    }

    func stop() {
        clipboard?.stop()
        clipboard = nil
        stopAudio()
    }

    private func startAudio(rate: Int, channels: Int) {
        guard settings.audioEnabled, audio == nil else { return }
        let server = self.server
        let capture = AudioCapture { server.submitAudio($0) }
        audio = capture
        let mute = settings.muteLocalAudio
        Task {
            do {
                try await capture.start(sampleRate: rate, channels: channels)
                if mute { localMute.mute() }
            } catch {
                log.error("Audio capture failed: \(error.localizedDescription, privacy: .public)")
                if audio === capture { audio = nil }
            }
        }
    }

    private func stopAudio() {
        localMute.restore()
        guard let capture = audio else { return }
        audio = nil
        Task { await capture.stop() }
    }
}
