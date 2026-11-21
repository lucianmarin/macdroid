import AVFoundation
import CoreMedia
import Foundation

/// Converts H.264 Annex-B NAL units from scrcpy into AVCC CMSampleBuffers for AVSampleBufferDisplayLayer.
public final class H264SampleBufferBuilder {
    private var sps: Data?
    private var pps: Data?
    private var formatDescription: CMVideoFormatDescription?

    public init() {}

    public func reset() {
        sps = nil
        pps = nil
        formatDescription = nil
    }

    public func buildSampleBuffer(from annexBData: Data, ptsMicroseconds: UInt64, isConfig: Bool) -> CMSampleBuffer? {
        let nalUnits = Self.splitAnnexBNALUnits(annexBData)
        var frameNALs: [Data] = []

        for nal in nalUnits where !nal.isEmpty {
            let nalType = nal[nal.startIndex] & 0x1F
            switch nalType {
            case 7:
                sps = nal
                updateFormatDescriptionIfReady()
            case 8:
                pps = nal
                updateFormatDescriptionIfReady()
            default:
                frameNALs.append(nal)
            }
        }

        guard !isConfig, !frameNALs.isEmpty, let formatDescription else {
            return nil
        }

        var avccData = Data()
        for nal in frameNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avccData.append(contentsOf: $0) }
            avccData.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let totalLength = avccData.count
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let replaceStatus = avccData.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: totalLength
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(ptsMicroseconds), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = totalLength
        var sampleBuffer: CMSampleBuffer?
        let sampleStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard sampleStatus == noErr else { return nil }
        return sampleBuffer
    }

    private func updateFormatDescriptionIfReady() {
        guard let sps, let pps else { return }
        sps.withUnsafeBytes { spsPtr in
            pps.withUnsafeBytes { ppsPtr in
                guard let spsBase = spsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsBase = ppsPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return
                }
                let pointers: [UnsafePointer<UInt8>] = [spsBase, ppsBase]
                let sizes: [Int] = [sps.count, pps.count]
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc
                )
                if status == noErr {
                    self.formatDescription = desc
                }
            }
        }
    }

    public static func splitAnnexBNALUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var startIndices: [(start: Int, length: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 {
                if bytes[i + 2] == 1 {
                    startIndices.append((i, 3))
                    i += 3
                    continue
                } else if i + 3 < bytes.count && bytes[i + 2] == 0 && bytes[i + 3] == 1 {
                    startIndices.append((i, 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }

        guard !startIndices.isEmpty else { return [] }
        var result: [Data] = []
        for idx in startIndices.indices {
            let nalStart = startIndices[idx].start + startIndices[idx].length
            let nalEnd = (idx + 1 < startIndices.count) ? startIndices[idx + 1].start : bytes.count
            if nalStart < nalEnd {
                result.append(Data(bytes[nalStart..<nalEnd]))
            }
        }
        return result
    }
}
