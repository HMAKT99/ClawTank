// Converts ScreenCaptureKit audio sample buffers (normally 32-bit float, non-interleaved) to the
// interleaved 16-bit little-endian PCM RDPSND carries.

import AVFoundation
import CoreMedia

enum PCMConverter {
    /// True when every sample is zero (digital silence).
    static func isSilent(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in raw.allSatisfy { $0 == 0 } }
    }

    /// Interleaved Int16 bytes for `channels` output channels, or nil if the buffer is unusable.
    static func int16Interleaved(_ sampleBuffer: CMSampleBuffer, channels: Int) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        var listSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &listSize, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let alignment = MemoryLayout<AudioBufferList>.alignment
        let raw = UnsafeMutableRawPointer.allocate(byteCount: listSize, alignment: alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: listSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block) == noErr
        else { return nil }

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let sourceChannels = Int(asbd.mChannelsPerFrame)
        guard isFloat, asbd.mBitsPerChannel == 32, sourceChannels > 0 else { return nil }

        func sample(_ frame: Int, _ channel: Int) -> Float {
            let source = min(channel, sourceChannels - 1)
            if nonInterleaved {
                guard source < buffers.count, let data = buffers[source].mData else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[frame]
            }
            guard let data = buffers[0].mData else { return 0 }
            return data.assumingMemoryBound(to: Float.self)[frame * sourceChannels + source]
        }

        var out = Data(count: frames * channels * 2)
        out.withUnsafeMutableBytes { bytes in
            let dest = bytes.bindMemory(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = max(-1, min(1, sample(frame, channel)))
                    dest[frame * channels + channel] = Int16(value * Float(Int16.max)).littleEndian
                }
            }
        }
        return out
    }
}
