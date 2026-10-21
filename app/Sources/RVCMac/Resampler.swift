import AVFoundation
import Foundation

/// Mono float32 sample-rate converter built on AVAudioConverter.
final class Resampler {
    let fromRate: Double
    let toRate: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat
    private let outFormat: AVAudioFormat

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

    private func makeInput(_ x: UnsafeBufferPointer<Float>) -> AVAudioPCMBuffer? {
        guard let buf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(max(x.count, 1))) else { return nil }
        buf.frameLength = AVAudioFrameCount(x.count)
        if let base = x.baseAddress, x.count > 0 {
            buf.floatChannelData![0].update(from: base, count: x.count)
        }
        return buf
    }

    /// Continuous stream conversion: converter state is kept between calls.
    func stream(_ x: UnsafeBufferPointer<Float>) -> [Float] {
        guard x.count > 0 else { return [] }
        guard let converter else { return Array(x) }
        guard let input = makeInput(x) else { return [] }
        let cap = AVAudioFrameCount(Double(x.count) * toRate / fromRate + 256)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return [] }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }

    /// Converts an independent segment and returns exactly `outCount` samples.
    func segment(_ x: [Float], outCount: Int) -> [Float] {
        guard let converter else {
            if x.count >= outCount { return Array(x[0..<outCount]) }
            return x + [Float](repeating: 0, count: outCount - x.count)
        }
        converter.reset()
        let input = x.withUnsafeBufferPointer { makeInput($0) }
        guard let input else { return [Float](repeating: 0, count: outCount) }
        let cap = AVAudioFrameCount(outCount + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else {
            return [Float](repeating: 0, count: outCount)
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
            return input
        }
        let n = Int(out.frameLength)
        var result = [Float](repeating: 0, count: outCount)
        let copy = min(n, outCount)
        if copy > 0 {
            result.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: out.floatChannelData![0], count: copy)
            }
        }
        return result
    }
}
