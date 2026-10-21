// File copy/paste over the clipboard channel.
//
// LocalFileList: what the Mac copied (Finder file URLs), flattened into the ordered list RDP
// uses (folders and their contents with relative paths), and served by index on request.
//
// FileReceiver: downloads what the client copied into ~/Downloads/ClawTank/<time>/, one 1 MiB
// chunk at a time, then puts the downloaded items on the pasteboard so ⌘V in Finder works.
// Every path from the client is sanitized again here (IronRDP already does): no "..", no
// absolute paths, no empty or hidden-dot-only components.

import AppKit
import os

struct LocalFileList {
    let entries: [RdpServer.RemoteFile]
    let urls: [URL?]  // nil for folders

    /// Flattens `roots` (files and folders) in a stable order.
    static func build(from roots: [URL]) -> LocalFileList {
        var entries: [RdpServer.RemoteFile] = []
        var urls: [URL?] = []
        let files = FileManager.default
        for root in roots {
            let values = try? root.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                entries.append(.init(path: root.lastPathComponent, size: 0, isDirectory: true))
                urls.append(nil)
                let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey]
                let enumerator = files.enumerator(at: root, includingPropertiesForKeys: keys)
                let children = (enumerator?.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
                // The enumerator returns symlink-resolved URLs (/private/var/…); resolve the
                // root the same way before taking the relative part.
                let rootPath = root.resolvingSymlinksInPath().path
                for child in children {
                    let childPath = child.resolvingSymlinksInPath().path
                    guard childPath.hasPrefix(rootPath + "/") else { continue }
                    let relative = root.lastPathComponent + "/" + childPath.dropFirst(rootPath.count + 1)
                    let childValues = try? child.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    let isDir = childValues?.isDirectory == true
                    let size = UInt64(childValues?.fileSize ?? 0)
                    entries.append(.init(path: relative, size: size, isDirectory: isDir))
                    urls.append(isDir ? nil : child)
                }
            } else {
                entries.append(.init(path: root.lastPathComponent, size: UInt64(values?.fileSize ?? 0),
                                     isDirectory: false))
                urls.append(root)
            }
        }
        return LocalFileList(entries: entries, urls: urls)
    }

    /// Answers a client request for entry `index`.
    func answer(index: Int, query: RdpServer.FileQuery) -> RdpServer.FileAnswer {
        guard entries.indices.contains(index), let url = urls[index] else { return .error }
        switch query {
        case .size:
            return .size(entries[index].size)
        case .range(let position, let length):
            guard let handle = try? FileHandle(forReadingFrom: url) else { return .error }
            defer { try? handle.close() }
            do {
                try handle.seek(toOffset: position)
                return .data(try handle.read(upToCount: min(length, 16 << 20)) ?? Data())
            } catch {
                return .error
            }
        }
    }
}

/// Serves the client's file-contents requests off the main thread (they arrive on the core's
/// thread at high rate during a copy), keeping the current file open between chunks.
final class FileServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.clawtank.files", qos: .userInitiated)
    private let lock = NSLock()
    private var list: LocalFileList?
    private var open: (index: Int, handle: FileHandle)?
    private weak var server: RdpServer?

    /// The server to answer through (set once it exists).
    func attach(_ server: RdpServer) {
        lock.withLock { self.server = server }
    }

    func setList(_ list: LocalFileList?) {
        lock.withLock {
            self.list = list
            try? open?.handle.close()
            open = nil
        }
    }

    func serve(stream: UInt32, index: Int, query: RdpServer.FileQuery) {
        queue.async { [self] in
            let answer = answer(index: index, query: query)
            lock.withLock { server }?.clipboardAnswerFile(stream: stream, answer)
        }
    }

    private func answer(index: Int, query: RdpServer.FileQuery) -> RdpServer.FileAnswer {
        lock.withLock {
            guard let list, list.entries.indices.contains(index), let url = list.urls[index] else { return .error }
            switch query {
            case .size:
                return .size(list.entries[index].size)
            case .range(let position, let length):
                if open?.index != index {
                    try? open?.handle.close()
                    open = (try? FileHandle(forReadingFrom: url)).map { (index, $0) }
                }
                guard let handle = open?.handle else { return .error }
                do {
                    try handle.seek(toOffset: position)
                    return .data(try handle.read(upToCount: min(length, 16 << 20)) ?? Data())
                } catch {
                    return .error
                }
            }
        }
    }
}

enum TransferPaths {
    /// A safe relative path inside the download folder, or nil if the remote path is unusable.
    static func sanitize(_ remote: String) -> String? {
        let parts = remote.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
        var clean: [String] = []
        for part in parts {
            let component = part.replacingOccurrences(of: ":", with: "-")
                .trimmingCharacters(in: .whitespaces)
            if component.isEmpty || component == "." || component == ".." || component.contains("\0") {
                return nil
            }
            clean.append(component)
        }
        return clean.isEmpty ? nil : clean.joined(separator: "/")
    }
}

@MainActor
final class FileReceiver {
    static let chunk = 1 << 20

    private let server: RdpServer
    private let files: [RdpServer.RemoteFile]
    private let folder: URL
    private let onStatus: (String?) -> Void
    private let onFinished: ([URL]) -> Void
    private var index = 0
    private var position: UInt64 = 0
    private var handle: FileHandle?
    private var stream: UInt32 = 0
    private var done: UInt64 = 0
    private let total: UInt64
    private let log = Logger(subsystem: "dev.clawtank.ClawTank", category: "files")

    init?(server: RdpServer, files: [RdpServer.RemoteFile], downloads: URL,
          onStatus: @escaping (String?) -> Void, onFinished: @escaping ([URL]) -> Void) {
        self.server = server
        self.files = files
        self.onStatus = onStatus
        self.onFinished = onFinished
        total = files.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: ".")
        folder = downloads.appendingPathComponent("ClawTank/\(stamp)", isDirectory: true)
        let free = (try? downloads.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        guard Int64(total) + 200_000_000 < free else {
            onStatus("Not enough disk space to receive \(Self.format(total))")
            return nil
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func start() {
        log.info("Receiving \(self.files.count) items, \(self.total) bytes into \(self.folder.path, privacy: .public)")
        advance()
    }

    /// Contents arrived for some stream; continue if it's ours.
    func contentsArrived(stream arrived: UInt32) {
        guard arrived == stream, let result = server.clipboardTakeFile(stream: stream) else { return }
        guard let data = result else {
            log.error("Client failed to send \(self.files[self.index].path, privacy: .public)")
            nextFile()
            return
        }
        try? handle?.write(contentsOf: data)
        position += UInt64(data.count)
        done += UInt64(data.count)
        onStatus("Receiving files: \(Int(Double(done) / Double(max(total, 1)) * 100))% of \(Self.format(total))")
        if data.isEmpty || position >= files[index].size {
            nextFile()
        } else {
            requestChunk()
        }
    }

    private func advance() {
        while index < files.count {
            let file = files[index]
            guard let relative = TransferPaths.sanitize(file.path) else {
                log.error("Skipping unsafe path from client: \(file.path, privacy: .public)")
                index += 1
                continue
            }
            let target = folder.appendingPathComponent(relative)
            if file.isDirectory {
                try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                index += 1
                continue
            }
            try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: target.path, contents: nil)
            handle = try? FileHandle(forWritingTo: target)
            position = 0
            if file.size == 0 {
                nextFile()
            } else {
                requestChunk()
            }
            return
        }
        finish()
    }

    private func requestChunk() {
        let remaining = files[index].size - position
        let length = Int(min(remaining, UInt64(Self.chunk)))
        stream = server.clipboardRequestFile(index: index, position: position, length: length)
        if stream == 0 { nextFile() }
    }

    private func nextFile() {
        try? handle?.close()
        handle = nil
        index += 1
        advance()
    }

    private func finish() {
        let tops = Set(files.compactMap {
            TransferPaths.sanitize($0.path)?.split(separator: "/").first.map(String.init)
        })
        let urls = tops.sorted().map { folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        onStatus("Received \(files.count) item(s) into Downloads/ClawTank")
        onFinished(urls)
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
