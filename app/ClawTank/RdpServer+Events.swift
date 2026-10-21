// RdpServer: decoding core events (kind + detail string) into `RdpServer.Event`.

import ClawTankCore
import Foundation

extension RdpServer {
    static func decodeFiles(_ detail: String) -> [RemoteFile] {
        detail.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3, let size = UInt64(parts[0]) else { return nil }
            return RemoteFile(path: parts[2], size: size, isDirectory: parts[1] == "1")
        }
    }

    static func decodeFileRequest(_ detail: String) -> Event? {
        let parts = detail.split(separator: "\t").map(String.init)
        guard parts.count >= 3, let stream = UInt32(parts[0]), let index = Int(parts[1]) else { return nil }
        if parts[2] == "size" { return .clipboardFileRequested(stream: stream, index: index, query: .size) }
        guard parts.count == 5, let position = UInt64(parts[3]), let length = Int(parts[4]) else { return nil }
        let query = FileQuery.range(position: position, length: length)
        return .clipboardFileRequested(stream: stream, index: index, query: query)
    }

    static func decodeMedia(kind: CtEventKind, detail: String) -> Event? {
        switch kind {
        case CT_EVENT_KIND_AUDIO_START:
            let parts = detail.split(separator: "x").compactMap { Int($0) }
            return parts.count == 2 ? .audioStart(rate: parts[0], channels: parts[1]) : .error("bad audio \(detail)")
        case CT_EVENT_KIND_AUDIO_STOP: return .audioStop
        default: return decodeClipboard(kind: kind, detail: detail)
        }
    }

    static func decodeClipboard(kind: CtEventKind, detail: String) -> Event? {
        switch kind {
        case CT_EVENT_KIND_CLIPBOARD_READY: return .clipboardReady
        case CT_EVENT_KIND_CLIPBOARD_REMOTE_FORMATS:
            let formats = detail.split(separator: "\n").compactMap { line -> ClipboardFormatRef? in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard let id = UInt32(parts[0]) else { return nil }
                return ClipboardFormatRef(id: id, name: parts.count > 1 ? parts[1] : nil)
            }
            return .clipboardRemoteFormats(formats)
        case CT_EVENT_KIND_CLIPBOARD_DATA_REQUESTED: return UInt32(detail).map { .clipboardDataRequested(format: $0) }
        case CT_EVENT_KIND_CLIPBOARD_DATA: return UInt32(detail).map { .clipboardData(format: $0) }
        case CT_EVENT_KIND_CLIPBOARD_REMOTE_FILES: return .clipboardRemoteFiles(decodeFiles(detail))
        case CT_EVENT_KIND_CLIPBOARD_FILE_REQUESTED: return decodeFileRequest(detail)
        case CT_EVENT_KIND_CLIPBOARD_FILE_CONTENTS: return UInt32(detail).map { .clipboardFileContents(stream: $0) }
        default: return nil
        }
    }

    static func decodeVideo(kind: CtEventKind, detail: String) -> Event? {
        if let media = decodeMedia(kind: kind, detail: detail) { return media }
        switch kind {
        case CT_EVENT_KIND_VIDEO_START:
            let size = detail.split(separator: "x").compactMap { Int($0) }
            return size.count == 2 ? .videoStart(width: size[0], height: size[1]) : .error("bad video size \(detail)")
        case CT_EVENT_KIND_VIDEO_STOP:
            return .videoStop
        case CT_EVENT_KIND_VIDEO_RESIZE:
            let parts = detail.split(whereSeparator: { $0 == "x" || $0 == "@" }).compactMap { Int($0) }
            return parts.count == 3 ? .videoResize(width: parts[0], height: parts[1], scalePercent: parts[2])
                : .error("bad resize \(detail)")
        default:
            return nil
        }
    }

    static func decode(kind: CtEventKind, detail: String) -> Event {
        let parts = detail.split(separator: "\n", maxSplits: 1).map(String.init)
        let peer = parts.first ?? ""
        let error = parts.count > 1 ? parts[1] : nil
        if let video = decodeVideo(kind: kind, detail: detail) { return video }
        switch kind {
        case CT_EVENT_KIND_LISTENING: return .listening(detail)
        case CT_EVENT_KIND_REJECTED: return .rejected(peer: peer, reason: error ?? "")
        case CT_EVENT_KIND_LOCKED_OUT: return .lockedOut(ip: peer, minutes: Int(error ?? "") ?? 0)
        case CT_EVENT_KIND_CLIENT_CONNECTED: return .clientConnected(detail)
        case CT_EVENT_KIND_CLIENT_DISCONNECTED: return .clientDisconnected(peer: peer, error: error)
        case CT_EVENT_KIND_CONNECTION_FAILED: return .connectionFailed(peer: peer, error: error ?? "unknown error")
        case CT_EVENT_KIND_STOPPED: return .stopped
        default: return .error(detail)
        }
    }
}
