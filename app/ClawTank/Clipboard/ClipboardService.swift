// Shares the clipboard both ways while a client is connected.
//
// Mac → client: every 0.5 s check NSPasteboard's changeCount; when it changes (and the change
// isn't ours), announce the available formats; serve data when the client pastes.
// Client → Mac: when the client copies, fetch every format we understand right away, then write
// them to NSPasteboard together (a lazy pasteboard provider would have to block the main thread
// on the network). Our own writes are remembered by changeCount so they never echo back.

import AppKit
import os

@MainActor
final class ClipboardService {
    private let server: RdpServer
    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastSeenChange: Int
    private var ourChange: Int?
    private var ready = false
    /// Formats requested from the client for the current remote copy, and what's arrived.
    private var pending: [UInt32: String] = [:]
    private var received: [String: Data] = [:]
    private var deadline: Date?
    private var localFiles: LocalFileList?
    private var receiver: FileReceiver?
    /// Progress text for the menu (nil when idle).
    var onTransferStatus: (String?) -> Void = { _ in }
    static let fileListName = "FileGroupDescriptorW"
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "clipboard")

    private let fileServer: FileServer?

    init(server: RdpServer, pasteboard: NSPasteboard = .general, fileServer: FileServer? = nil) {
        self.server = server
        self.fileServer = fileServer
        self.pasteboard = pasteboard
        self.lastSeenChange = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func stop() {
        receiver = nil
        localFiles = nil
        fileServer?.setList(nil)
        onTransferStatus(nil)
        timer?.invalidate()
        timer = nil
        ready = false
        pending.removeAll()
        received.removeAll()
    }

    // MARK: Events from the core

    /// Channel ready, or the client asked for our formats.
    func channelReady() {
        ready = true
        announce()
    }

    func remoteCopied(_ formats: [RdpServer.ClipboardFormatRef]) {
        pending.removeAll()
        received.removeAll()
        // Files take precedence: fetch the list; contents follow once it arrives.
        if let files = formats.first(where: { $0.name == Self.fileListName }) {
            server.clipboardRequest(files.id)
            return
        }
        for format in formats {
            if let kind = Self.kind(of: format) { pending[format.id] = kind }
        }
        // Prefer PNG over DIB when both are offered.
        if pending.values.contains("png"), let dib = pending.first(where: { $0.value == "dib" })?.key {
            pending[dib] = nil
        }
        guard !pending.isEmpty else { return }
        deadline = Date().addingTimeInterval(5)
        for id in pending.keys.sorted() { server.clipboardRequest(id) }
    }

    /// Which of our supported kinds a client format is, if any.
    static func kind(of format: RdpServer.ClipboardFormatRef) -> String? {
        switch (format.id, format.name) {
        case (ClipboardFormats.unicodeText, _): "text"
        case (ClipboardFormats.dib, _): "dib"
        case (_, ClipboardFormats.rtfName?): "rtf"
        case (_, ClipboardFormats.htmlName?): "html"
        case (_, ClipboardFormats.pngName?): "png"
        default: nil
        }
    }

    func remoteDataArrived() {
        while let (format, data) = server.clipboardTakeData() {
            guard let kind = pending.removeValue(forKey: format) else { continue }
            if let data { received[kind] = data }
        }
        if pending.isEmpty { writeReceived() }
    }

    func remoteFilesListed(_ files: [RdpServer.RemoteFile]) {
        guard !files.isEmpty, receiver == nil else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let receiver = FileReceiver(server: server, files: files, downloads: downloads, onStatus: { [weak self] in
            self?.onTransferStatus($0)
        }, onFinished: { [weak self] urls in
            self?.receiver = nil
            self?.putFilesOnPasteboard(urls)
        })
        self.receiver = receiver
        receiver?.start()
    }

    func fileContentsArrived(stream: UInt32) {
        receiver?.contentsArrived(stream: stream)
    }

    func fileRequested(stream: UInt32, index: Int, query: RdpServer.FileQuery) {
        server.clipboardAnswerFile(stream: stream, localFiles?.answer(index: index, query: query) ?? .error)
    }

    private func putFilesOnPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        ourChange = pasteboard.changeCount
        lastSeenChange = pasteboard.changeCount
    }

    func dataRequested(_ format: UInt32) {
        server.clipboardProvide(localData(for: format))
    }

    // MARK: Mac → client

    private func poll() {
        if let deadline, Date() > deadline, !pending.isEmpty {
            log.notice("Clipboard fetch timed out; writing what arrived")
            pending.removeAll()
            writeReceived()
        }
        let change = pasteboard.changeCount
        guard change != lastSeenChange else { return }
        lastSeenChange = change
        if change == ourChange { return }
        announce()
    }

    private func announce() {
        guard ready else { return }
        let fileURLs = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL] ?? []
        if !fileURLs.isEmpty {
            let list = LocalFileList.build(from: fileURLs)
            localFiles = list
            fileServer?.setList(list)
            server.clipboardAnnounceFiles(list.entries)
            return
        }
        localFiles = nil
        fileServer?.setList(nil)
        let types = Set(pasteboard.types ?? [])
        var formats: [RdpServer.ClipboardFormatRef] = []
        if types.contains(.string) { formats.append(.init(id: ClipboardFormats.unicodeText, name: nil)) }
        if types.contains(.rtf) { formats.append(.init(id: ClipboardFormats.rtfID, name: ClipboardFormats.rtfName)) }
        if types.contains(.html) { formats.append(.init(id: ClipboardFormats.htmlID, name: ClipboardFormats.htmlName)) }
        if types.contains(.png) || types.contains(.tiff) {
            formats.append(.init(id: ClipboardFormats.pngID, name: ClipboardFormats.pngName))
            formats.append(.init(id: ClipboardFormats.dib, name: nil))
        }
        server.clipboardAnnounce(formats)
    }

    func localData(for format: UInt32) -> Data? {
        switch format {
        case ClipboardFormats.unicodeText:
            return pasteboard.string(forType: .string).map(ClipboardFormats.encodeUnicodeText)
        case ClipboardFormats.rtfID:
            return pasteboard.data(forType: .rtf)
        case ClipboardFormats.htmlID:
            return pasteboard.string(forType: .html).map(ClipboardFormats.encodeHTML)
        case ClipboardFormats.pngID:
            if let png = pasteboard.data(forType: .png) { return png }
            return bitmap()?.representation(using: .png, properties: [:])
        case ClipboardFormats.dib:
            return bitmap().flatMap(ClipboardFormats.encodeDIB)
        default:
            return nil
        }
    }

    private func bitmap() -> NSBitmapImageRep? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            return NSBitmapImageRep(data: data)
        }
        return nil
    }

    // MARK: Client → Mac

    private func writeReceived() {
        deadline = nil
        guard !received.isEmpty else { return }
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let data = received["text"], let text = ClipboardFormats.decodeUnicodeText(data) {
            item.setString(text, forType: .string)
        }
        if let rtf = received["rtf"] { item.setData(rtf.prefix { $0 != 0 }, forType: .rtf) }
        if let data = received["html"], let html = ClipboardFormats.decodeHTML(data) {
            item.setString(html, forType: .html)
        }
        if let png = received["png"] {
            item.setData(png, forType: .png)
        } else if let dib = received["dib"], let rep = ClipboardFormats.decodeDIB(dib),
                  let png = rep.representation(using: .png, properties: [:]) {
            item.setData(png, forType: .png)
            if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        }
        pasteboard.writeObjects([item])
        ourChange = pasteboard.changeCount
        lastSeenChange = ourChange ?? lastSeenChange
        log.info("Clipboard from client: \(self.received.keys.sorted().joined(separator: ","), privacy: .public)")
        received.removeAll()
    }
}
