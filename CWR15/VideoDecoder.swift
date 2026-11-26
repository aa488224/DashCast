import AVFoundation
import VideoToolbox

/// 把主端发来的 AVCC 样本直接喂给 AVSampleBufferDisplayLayer，由 A9 的 H.264 硬解负责出图。
final class VideoDecoder {

    private weak var layer: AVSampleBufferDisplayLayer?
    private var format: CMVideoFormatDescription?
    private var videoSize: CGSize = .zero
    private var needsKeyframe = true
    private var decodedFrames = 0
    private var lastLog = Date()

    var onSize: ((CGSize) -> Void)?
    var onNeedKeyframe: (() -> Void)?
    /// 渲染层状态异常（failed / 长时间无帧）时上报。
    var onStalled: ((String) -> Void)?

    init(layer: AVSampleBufferDisplayLayer) {
        self.layer = layer
    }

    // MARK: 配置

    func configure(_ info: VideoFormatInfo) {
        guard let avcC = info.avcC else {
            Log.shared.warn("[解码] 没有收到 avcC 参数集，无法建立解码器")
            onNeedKeyframe?()
            return
        }
        guard let sets = Self.parseParameterSets(avcC) else {
            Log.shared.error("[解码] avcC 解析失败（\(avcC.count) 字节）")
            return
        }
        var description: CMVideoFormatDescription?
        var status: OSStatus = -1
        sets.sps.withUnsafeBytes { spsRaw in
            sets.pps.withUnsafeBytes { ppsRaw in
                guard let sps = spsRaw.bindMemory(to: UInt8.self).baseAddress,
                      let pps = ppsRaw.bindMemory(to: UInt8.self).baseAddress else { return }
                var pointers: [UnsafePointer<UInt8>] = [sps, pps]
                var sizes: [Int] = [sets.sps.count, sets.pps.count]
                pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        guard let pointerBase = pointerBuffer.baseAddress,
                              let sizeBase = sizeBuffer.baseAddress else { return }
                        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBase,
                            parameterSetSizes: sizeBase,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description)
                    }
                }
            }
        }
        guard status == noErr, let description else {
            Log.shared.error("[解码] 无法创建 H.264 格式描述（\(status)）")
            return
        }
        format = description
        needsKeyframe = true
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        videoSize = CGSize(width: Int(dims.width), height: Int(dims.height))
        Log.shared.info("[解码] H.264 \(Int(dims.width))×\(Int(dims.height))，SPS \(sets.sps.count) 字节 / PPS \(sets.pps.count) 字节")
        onSize?(videoSize)
        onNeedKeyframe?()
    }

    // MARK: 送帧

    func enqueue(_ data: Data, keyframe: Bool, timestampUs: UInt64) {
        guard let layer, let format else { return }
        if needsKeyframe && !keyframe { return }

        guard let sample = makeSampleBuffer(data, format: format, keyframe: keyframe, timestampUs: timestampUs) else {
            Log.shared.warn("[解码] 样本构造失败（\(data.count) 字节）")
            return
        }
        needsKeyframe = false

        if layer.status == .failed {
            Log.shared.warn("[解码] 渲染层失败：\(layer.error?.localizedDescription ?? "未知")，重新排队")
            layer.flush()
            needsKeyframe = true
            onNeedKeyframe?()
            return
        }
        layer.enqueue(sample)
        decodedFrames += 1

        if decodedFrames == 1 {
            Log.shared.info("[解码] 第一帧已送入渲染层")
        }
        if Date().timeIntervalSince(lastLog) >= 10 {
            lastLog = Date()
            Log.shared.info("[解码] 已送入 \(decodedFrames) 帧，渲染层 \(layer.status == .rendering ? "正常" : "状态 \(layer.status.rawValue)")")
        }
    }

    func reset() {
        layer?.flush()
        format = nil
        needsKeyframe = true
        decodedFrames = 0
        Log.shared.info("[解码] 已重置")
    }

    // MARK: 构造 CMSampleBuffer

    private func makeSampleBuffer(_ data: Data, format: CMVideoFormatDescription, keyframe: Bool, timestampUs: UInt64) -> CMSampleBuffer? {
        let length = data.count
        guard length > 0 else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block) == noErr, let block else { return nil }

        let copied: OSStatus = data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: CMTimeValue(timestampUs), timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sampleSize = length
        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }

        if !keyframe {
            CMSetAttachment(sample, key: kCMSampleAttachmentKey_NotSync,
                            value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        CMSetAttachment(sample, key: kCMSampleAttachmentKey_DisplayImmediately,
                        value: kCFBooleanTrue, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return sample
    }

    // MARK: avcC

    /// 从 AVCDecoderConfigurationRecord 里取第一组 SPS/PPS。
    static func parseParameterSets(_ data: Data) -> (sps: Data, pps: Data)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        var index = 5
        let spsCount = Int(bytes[index] & 0x1F)
        index += 1
        guard spsCount >= 1 else { return nil }

        var sps: Data?
        for i in 0..<spsCount {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { return nil }
            if i == 0 { sps = Data(bytes[index..<index + length]) }
            index += length
        }
        guard index + 1 <= bytes.count else { return nil }
        let ppsCount = Int(bytes[index])
        index += 1
        guard ppsCount >= 1 else { return nil }

        var pps: Data?
        for i in 0..<ppsCount {
            guard index + 2 <= bytes.count else { return nil }
            let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
            index += 2
            guard length > 0, index + length <= bytes.count else { return nil }
            if i == 0 { pps = Data(bytes[index..<index + length]) }
            index += length
        }
        guard let sps, let pps else { return nil }
        return (sps, pps)
    }
}
