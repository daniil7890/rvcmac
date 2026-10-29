import AVFoundation
import Foundation

/// Mono float32 sample-rate converter built on AVAudioConverter.
/// PCM buffers are kept between calls and only grow, so steady-state calls do not allocate them.
final class Resampler {
    let fromRate: Double
    let toRate: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat
    private var inBuf: AVAudioPCMBuffer?
    private var outBuf: AVAudioPCMBuffer?

    init(from: Double, to: Double) {
        fromRate = from
        toRate = to
        inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false)!
        outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false)!
        if from == to {
            converter = nil
        } else {
            let c = AVAudioConverter(from: inFormat, to: outFormat)
            c?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = c
        }
    }

    /// Upper bound of output samples for `n` input samples.
    func maxOutput(for n: Int) -> Int { Int(Double(n) * toRate / fromRate) + 256 }

    private func input(_ x: UnsafeBufferPointer<Float>) -> AVAudioPCMBuffer? {
        let need = AVAudioFrameCount(max(x.count, 1))
        if inBuf == nil || inBuf!.frameCapacity < need {
            inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: max(need, 4096))
        }
        guard let buf = inBuf else { return nil }
        buf.frameLength = AVAudioFrameCount(x.count)
        if let base = x.baseAddress, x.count > 0 { buf.floatChannelData![0].update(from: base, count: x.count) }
        return buf
    }

    private func output(capacity: Int) -> AVAudioPCMBuffer? {
        let need = AVAudioFrameCount(capacity)
        if outBuf == nil || outBuf!.frameCapacity < need {
            outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: max(need, 4096))
        }
        outBuf?.frameLength = 0
        return outBuf
    }

    /// Continuous stream conversion (converter state is kept between calls).
    /// Writes at most `capacity` samples to `dst` and returns how many were written.
    func stream(_ x: UnsafeBufferPointer<Float>, into dst: UnsafeMutablePointer<Float>, capacity: Int) -> Int {
        guard x.count > 0, let base = x.baseAddress else { return 0 }
        guard let converter else {
            let n = min(x.count, capacity)
            dst.update(from: base, count: n)
            return n
        }
        guard let inp = input(x), let out = output(capacity: maxOutput(for: x.count)) else { return 0 }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inp
        }
        let n = min(Int(out.frameLength), capacity)
        if n > 0 { dst.update(from: out.floatChannelData![0], count: n) }
        return n
    }

    /// Convenience for non-real-time callers (benchmark file loading).
    func stream(_ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: maxOutput(for: x.count))
        let n = x.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { stream(src, into: $0.baseAddress!, capacity: $0.count) }
        }
        out.removeLast(out.count - n)
        return out
    }

    /// Converts an independent segment and writes exactly `outCount` samples to `dst` (zero-padded).
    func segment(_ x: UnsafeBufferPointer<Float>, into dst: UnsafeMutablePointer<Float>, outCount: Int) {
        guard let converter else {
            let n = min(x.count, outCount)
            if n > 0, let b = x.baseAddress { dst.update(from: b, count: n) }
            if n < outCount { (dst + n).update(repeating: 0, count: outCount - n) }
            return
        }
        converter.reset()
        guard let inp = input(x), let out = output(capacity: outCount + 1024) else {
            dst.update(repeating: 0, count: outCount)
            return
        }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inp
        }
        let n = min(Int(out.frameLength), outCount)
        if n > 0 { dst.update(from: out.floatChannelData![0], count: n) }
        if n < outCount { (dst + n).update(repeating: 0, count: outCount - n) }
    }
}
