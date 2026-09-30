import Foundation
import CoreMedia

/// Splits an H.264 / H.265 Annex-B byte stream into NAL units and turns them
/// into CMSampleBuffers (AVCC / HVCC length-prefixed) for VideoToolbox.
public struct AnnexBParser: Sendable {
    public enum Codec: Sendable { case h264, hevc }

    public var codec: Codec
    private var buffer: [UInt8] = []
    // Parameter sets seen so far.
    private var vps: [UInt8]?, sps: [UInt8]?, pps: [UInt8]?
    public private(set) var formatDescription: CMVideoFormatDescription?
    private var pendingAU: [[UInt8]] = []
    public private(set) var accessUnits = 0

    public init(codec: Codec) { self.codec = codec }

    public struct AccessUnit: @unchecked Sendable {
        public var sampleBuffer: CMSampleBuffer
        public var isKeyframe: Bool
        public var byteCount: Int
    }

    /// Feed bytes; returns complete access units that are ready to decode.
    public mutating func feed(_ bytes: [UInt8], presentation: CMTime = .invalid) -> [AccessUnit] {
        buffer.append(contentsOf: bytes)
        var out: [AccessUnit] = []
        // Find start codes; keep the last (possibly incomplete) NAL in the buffer.
        var starts: [Int] = []
        var i = 0
        while i + 3 <= buffer.count {
            if buffer[i] == 0, buffer[i+1] == 0, (buffer[i+2] == 1 || (i + 3 < buffer.count && buffer[i+2] == 0 && buffer[i+3] == 1)) {
                starts.append(i)
                i += buffer[i+2] == 1 ? 3 : 4
            } else { i += 1 }
        }
        guard starts.count >= 2 else { return out }
        for k in 0..<(starts.count - 1) {
            let s = starts[k], e = starts[k+1]
            let scLen = buffer[s+2] == 1 ? 3 : 4
            let nal = Array(buffer[(s + scLen)..<trimTrailingZeros(e)])
            if let au = handle(nal: nal, presentation: presentation) { out.append(au) }
        }
        buffer.removeFirst(starts[starts.count - 1])
        return out
    }

    private func trimTrailingZeros(_ end: Int) -> Int {
        var e = end
        while e > 0, buffer[e-1] == 0 { e -= 1 }   // the leading 0 of the next start code
        return e
    }

    private mutating func handle(nal: [UInt8], presentation: CMTime) -> AccessUnit? {
        guard !nal.isEmpty else { return nil }
        let type: Int
        let isVCL: Bool, isIDR: Bool, firstSliceInPicture: Bool
        switch codec {
        case .h264:
            type = Int(nal[0] & 0x1F)
            switch type {
            case 7: sps = nal; rebuildFormat(); return nil
            case 8: pps = nal; rebuildFormat(); return nil
            case 9, 6: return flushIfNeeded()     // AUD / SEI start a new picture
            default: break
            }
            isVCL = (1...5).contains(type); isIDR = type == 5
            firstSliceInPicture = isVCL && nal.count > 1 && (nal[1] & 0x80) != 0   // first_mb_in_slice == 0 (ue(v) leading 1)
        case .hevc:
            type = Int((nal[0] >> 1) & 0x3F)
            switch type {
            case 32: vps = nal; rebuildFormat(); return nil
            case 33: sps = nal; rebuildFormat(); return nil
            case 34: pps = nal; rebuildFormat(); return nil
            case 35, 39, 40: return flushIfNeeded()
            default: break
            }
            isVCL = type <= 31; isIDR = (16...21).contains(type)
            firstSliceInPicture = isVCL && nal.count > 2 && (nal[2] & 0x80) != 0   // first_slice_segment_in_pic_flag
        }
        guard isVCL else { return nil }
        var result: AccessUnit?
        if firstSliceInPicture, !pendingAU.isEmpty { result = emit(presentation: presentation) }
        pendingAU.append(nal)
        _ = isIDR
        return result
    }

    private mutating func flushIfNeeded() -> AccessUnit? { pendingAU.isEmpty ? nil : emit(presentation: .invalid) }

    /// Force out whatever picture is pending (call at end of stream).
    public mutating func flush() -> AccessUnit? { flushIfNeeded() }

    private mutating func emit(presentation: CMTime) -> AccessUnit? {
        defer { pendingAU.removeAll() }
        guard let fd = formatDescription else { return nil }
        var avcc: [UInt8] = []
        var key = false
        for nal in pendingAU {
            let n = UInt32(nal.count)
            avcc += [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
            avcc += nal
            switch codec {
            case .h264: if nal[0] & 0x1F == 5 { key = true }
            case .hevc: if (16...21).contains(Int((nal[0] >> 1) & 0x3F)) { key = true }
            }
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentation, decodeTimeStamp: .invalid)
        var size = avcc.count
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fd, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        accessUnits += 1
        return AccessUnit(sampleBuffer: sample, isKeyframe: key, byteCount: avcc.count)
    }

    private mutating func rebuildFormat() {
        guard let sps, let pps else { return }
        var fd: CMVideoFormatDescription?
        switch codec {
        case .h264:
            sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
                let sets = [s.baseAddress!, p.baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                    parameterSetPointers: sets, parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            } }
        case .hevc:
            guard let vps else { return }
            vps.withUnsafeBufferPointer { v in sps.withUnsafeBufferPointer { s in pps.withUnsafeBufferPointer { p in
                let sets = [v.baseAddress!, s.baseAddress!, p.baseAddress!]
                let sizes = [vps.count, sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 3,
                                                                    parameterSetPointers: sets, parameterSetSizes: sizes,
                                                                    nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
            } } }
        }
        if let fd { formatDescription = fd }
    }
}
