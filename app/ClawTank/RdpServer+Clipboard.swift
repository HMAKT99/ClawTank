// RdpServer: clipboard and file-transfer calls into the core (see Clipboard/).

import ClawTankCore
import Foundation

extension RdpServer {
    @discardableResult
    func clipboardAnnounce(_ formats: [ClipboardFormatRef]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        let ids = formats.map(\.id)
        let names = formats.map { $0.name.flatMap { strdup($0) } }
        defer { names.forEach { free($0) } }
        let pointers = names.map { UnsafePointer($0) }
        return ids.withUnsafeBufferPointer { idBuffer in
            pointers.withUnsafeBufferPointer { nameBuffer in
                ct_clipboard_announce(handle, idBuffer.baseAddress, nameBuffer.baseAddress, formats.count)
            }
        }
    }

    /// Answers the client's pending request (nil = can't provide).
    @discardableResult
    func clipboardProvide(_ data: Data?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        guard let data else { return ct_clipboard_provide(handle, nil, 0, false) }
        return data.withUnsafeBytes {
            ct_clipboard_provide(handle, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, true)
        }
    }

    @discardableResult
    func clipboardRequest(_ format: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        return ct_clipboard_request(handle, format)
    }

    /// The oldest data received from the client: (format, data or nil on client error).
    func clipboardTakeData() -> (format: UInt32, data: Data?)? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var buffer = CtBuffer(data: nil, len: 0)
        var succeeded = false
        let format = ct_clipboard_take_data(handle, &buffer, &succeeded)
        defer { ct_buffer_free(buffer) }
        guard format != 0 else { return nil }
        let data = buffer.data.map { Data(bytes: $0, count: buffer.len) } ?? Data()
        return (format, succeeded ? data : nil)
    }

    /// Offers files (index = position in this list) to the client.
    @discardableResult
    func clipboardAnnounceFiles(_ files: [RemoteFile]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        let paths = files.map { strdup($0.path) }
        defer { paths.forEach { free($0) } }
        let entries = zip(files, paths).map { file, path in
            CtFileEntry(path: path, size: file.size, is_dir: file.isDirectory)
        }
        return entries.withUnsafeBufferPointer { ct_clipboard_announce_files(handle, $0.baseAddress, $0.count) }
    }

    @discardableResult
    func clipboardAnswerFile(stream: UInt32, _ answer: FileAnswer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return false }
        switch answer {
        case .size(let size): return ct_clipboard_answer_file(handle, stream, 1, nil, 0, size)
        case .error: return ct_clipboard_answer_file(handle, stream, 2, nil, 0, 0)
        case .data(let data):
            return data.withUnsafeBytes {
                ct_clipboard_answer_file(handle, stream, 0, $0.bindMemory(to: UInt8.self).baseAddress, $0.count, 0)
            }
        }
    }

    /// Requests a byte range of the client's file `index`; returns the stream id (0 = failed).
    func clipboardRequestFile(index: Int, position: UInt64, length: Int) -> UInt32 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return ct_clipboard_request_file(handle, UInt32(index), false, position, UInt32(clamping: length))
    }

    /// Takes contents that arrived for `stream`: nil = not yet; .some(nil) = client error.
    func clipboardTakeFile(stream: UInt32) -> Data?? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        var buffer = CtBuffer(data: nil, len: 0)
        var succeeded = false
        guard ct_clipboard_take_file(handle, stream, &buffer, &succeeded) else { return nil }
        defer { ct_buffer_free(buffer) }
        guard succeeded else { return .some(nil) }
        return .some(buffer.data.map { Data(bytes: $0, count: buffer.len) } ?? Data())
    }
}
