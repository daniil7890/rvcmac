import Accelerate
import CoreML
import Foundation
import RVCMacCore

struct EngineParams {
    var pitch: Int = 0          // semitones
    var gateDB: Float = -60     // input gate threshold
    var gain: Float = 1.0       // output gain
    var bypass = false          // pass input straight through (for checking routing)
    var indexRatio: Float = 0.5 // how much retrieved index features replace the input features
    var protect: Float = 0.33   // keep original features on unvoiced frames (0.5 = off)
}

/// Fast gaussian noise (xorshift + Box-Muller).
struct Gaussian {
    private var state: UInt64 = 0x9E3779B97F4A7C15
    private var spare: Float?
    mutating func next() -> Float {
        if let s = spare { spare = nil; return s }
        var u1: Float = 0
        repeat { u1 = uniform() } while u1 <= 1e-7
        let u2 = uniform()
        let r = sqrtf(-2 * logf(u1))
        let t = 2 * Float.pi * u2
        spare = r * sinf(t)
        return r * cosf(t)
    }
    private mutating func uniform() -> Float {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Float(state >> 40) / Float(1 << 24)
    }
}

@inline(__always) private func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
@inline(__always) private func msSince(_ t: UInt64) -> Double { Double(nowNs() &- t) / 1e6 }

/// One voice ready to run: Core ML models plus their reusable inputs, feature providers and scratch buffers.
/// Built off the worker thread, so a model switch only swaps a reference.
final class ModelState {
    let model: LoadedVoice
    let audioArray: MLMultiArray
    let pitchArray: MLMultiArray
    let noiseArray: MLMultiArray
    let sineArray: MLMultiArray
    let phoneArray: MLMultiArray
    let audioInput: MLFeatureProvider
    let synthInput: MLFeatureProvider
    let centTable: [Float]
    let outResampler: Resampler
    // scratch
    var dots: [Float] = []
    var phone: [Float] = []
    var latent: [Float] = []
    var audio: [Float] = []
    var mixed: [Float] = []

    init(model: LoadedVoice, outRate: Double) throws {
        self.model = model
        let cfg = model.config
        audioArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.N)], dataType: .float32)
        pitchArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.F)], dataType: .int32)
        noiseArray = try MLMultiArray(shape: [1, NSNumber(value: model.interChannels), NSNumber(value: cfg.F - cfg.flowHead)], dataType: .float32)
        sineArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.R * model.upp), 1], dataType: .float32)
        phoneArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.F), NSNumber(value: model.voice.embChannels)], dataType: .float32)
        audioInput = try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray])
        synthInput = try MLDictionaryFeatureProvider(dictionary: [
            "phone": phoneArray, "pitch": pitchArray, "noise": noiseArray, "sine": sineArray,
        ])
        let m = model.fcpe
        let c0 = 1200 * log2(m.f0Min / 10), c1 = 1200 * log2(m.f0Max / 10)
        centTable = (0..<m.outDims).map { Float(c0 + (c1 - c0) * Double($0) / Double(m.outDims - 1)) }
        outResampler = Resampler(from: Double(model.voice.sr), to: outRate)
    }
}

/// The DSP chain for one block, without any audio I/O. Used by the live engine and the file benchmark.
/// The maths is the same as before the telemetry work; only allocations were removed.
final class VoicePipeline {
    let cfg: LatencyConfig
    let outRate: Double
    private(set) var state: ModelState
    let block16: Int
    let window: Int
    let blockOut: Int
    let cfOut: Int
    let searchOut: Int
    let segOut: Int

    private var win: [Float]
    private var solaBuffer: [Float]
    private var fadeIn: [Float]
    private var fadeOut: [Float]
    private var seg: [Float]
    private var f0: [Float]
    private var rng = Gaussian()
    private let bypassResampler: Resampler
    private var switched = false

    /// Output of the last `process` call: `outCount` samples at `outRate`.
    private(set) var out: [Float]
    private(set) var outCount = 0
    private(set) var lastOffset = 0

    init(model: LoadedVoice, outRate: Double) throws {
        cfg = model.config
        self.outRate = outRate
        state = try ModelState(model: model, outRate: outRate)
        block16 = cfg.blockF * 160
        window = cfg.N
        let perFrame = Int(outRate) / 100
        blockOut = cfg.blockF * perFrame
        cfOut = cfg.crossfadeF * perFrame
        searchOut = cfg.solaF * perFrame
        segOut = cfg.R * perFrame
        win = [Float](repeating: 0, count: cfg.N)
        solaBuffer = [Float](repeating: 0, count: cfOut)
        let n = cfOut
        fadeIn = (0..<n).map { i in
            let t = n > 1 ? Float(i) / Float(n - 1) : 1
            let s = sinf(0.5 * .pi * t)
            return s * s
        }
        fadeOut = fadeIn.map { 1 - $0 }
        seg = [Float](repeating: 0, count: segOut)
        f0 = [Float](repeating: 0, count: cfg.F)
        bypassResampler = Resampler(from: 16000, to: outRate)
        out = [Float](repeating: 0, count: bypassResampler.maxOutput(for: block16) + blockOut)
    }

    /// Clears the audio history (between benchmark runs).
    func reset() {
        for i in 0..<win.count { win[i] = 0 }
        for i in 0..<solaBuffer.count { solaBuffer[i] = 0 }
        outCount = 0
    }

    /// Takes effect on the next block; the SOLA crossfade blends the old voice into the new one.
    func replaceModel(_ s: ModelState) {
        precondition(s.model.config.key == cfg.key, "model switch needs the same latency config")
        state = s
        switched = true
    }

    /// Processes one block of `block16` samples at 16 kHz into `out`.
    func process(_ block: UnsafeBufferPointer<Float>, params p: EngineParams, times: inout StageTimes) throws -> (db: Float, flags: BlockFlags) {
        let tBlock = nowNs()
        var flags: BlockFlags = []
        if switched { flags.insert(.modelSwitch); switched = false }
        let s = state
        let model = s.model

        // slide window
        win.withUnsafeMutableBufferPointer { w in
            let base = w.baseAddress!
            memmove(base, base + block16, (window - block16) * MemoryLayout<Float>.size)
            (base + window - block16).update(from: block.baseAddress!, count: block16)
        }

        // input level over the newest block + crossfade
        let lvlCount = min(window, block16 + cfg.crossfadeF * 160)
        var meanSq: Float = 0
        win.withUnsafeBufferPointer { b in
            vDSP_measqv(b.baseAddress! + (window - lvlCount), 1, &meanSq, vDSP_Length(lvlCount))
        }
        let db = 10 * log10f(meanSq + 1e-12)

        if p.bypass {
            let t = nowNs()
            outCount = out.withUnsafeMutableBufferPointer { bypassResampler.stream(block, into: $0.baseAddress!, capacity: $0.count) }
            if p.gain != 1 { for i in 0..<outCount { out[i] *= p.gain } }
            times[.output] = msSince(t)
            times[.total] = msSince(tBlock)
            flags.insert(.bypass)
            return (db, flags)
        }
        if db < p.gateDB {
            for i in 0..<blockOut { out[i] = 0 }
            outCount = blockOut
            times[.total] = msSince(tBlock)
            flags.insert(.gated)
            return (db, flags)
        }

        // 1. ContentVec
        var t = nowNs()
        win.withUnsafeBufferPointer { b in
            s.audioArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: b.baseAddress!, count: window)
        }
        let embOut = try model.embedder.prediction(from: s.audioInput)
        guard let phone = embOut.featureValue(for: model.voice.embOutput)?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "embedder output missing"])
        }
        Self.copy(phone, into: &s.phone)
        times[.embedder] = msSince(t)

        // 2. FCPE -> f0 per 10 ms frame
        t = nowNs()
        let pitchOut = try model.pitchModel.prediction(from: s.audioInput)
        guard let latent = pitchOut.featureValue(for: "latent")?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "fcpe output missing"])
        }
        Self.copy(latent, into: &s.latent)
        decodeF0(s)
        let shift = powf(2, Float(p.pitch) / 12)
        for i in 0..<f0.count { f0[i] *= shift }
        times[.pitch] = msSince(t)

        // 3. features: index retrieval on 20 ms frames, x2 upscale to 10 ms frames, protect
        t = nowNs()
        buildFeatures(s, params: p)
        times[.features] = msSince(t)

        // 4. coarse pitch for the encoder, NSF excitation (same maths as RVC SineGen), prior noise
        t = nowNs()
        let melMin: Float = 1127 * logf(1 + 50 / 700), melMax: Float = 1127 * logf(1 + 1100 / 700)
        let pitchPtr = s.pitchArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<cfg.F {
            var mel = 1127 * logf(1 + f0[i] / 700)
            mel = (mel - melMin) * 254 / (melMax - melMin) + 1
            pitchPtr[i] = Int32(max(1, min(255, mel.rounded())))
        }
        let upp = model.upp
        let sr = Double(model.voice.sr)
        let sinePtr = s.sineArray.dataPointer.assumingMemoryBound(to: Float.self)
        var phase = 0.0
        for i in 0..<cfg.R {
            let f = Double(f0[cfg.skip + i])
            let voiced = f > 0
            let step = f / sr
            for j in 0..<upp {
                phase += step
                phase -= floor(phase)
                let idx = i * upp + j
                if voiced {
                    sinePtr[idx] = Float(sin(2 * Double.pi * phase)) * 0.1 + 0.003 * rng.next()
                } else {
                    sinePtr[idx] = (0.1 / 3) * rng.next()
                }
            }
        }
        let noisePtr = s.noiseArray.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<s.noiseArray.count { noisePtr[i] = rng.next() }
        times[.excitation] = msSince(t)

        // 5. synthesizer
        t = nowNs()
        let synthOut = try model.synth.prediction(from: s.synthInput)
        guard let audio = synthOut.featureValue(for: "audio")?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 3, userInfo: [NSLocalizedDescriptionKey: "synth output missing"])
        }
        Self.copy(audio, into: &s.audio)
        times[.synth] = msSince(t)

        // 6. to output rate, SOLA crossfade
        t = nowNs()
        s.audio.withUnsafeBufferPointer { a in
            seg.withUnsafeMutableBufferPointer { s.outResampler.segment(a, into: $0.baseAddress!, outCount: segOut) }
        }
        sola(gain: p.gain)
        outCount = blockOut
        times[.output] = msSince(t)
        times[.total] = msSince(tBlock)
        return (db, flags)
    }

    /// ContentVec frames [E x C] -> phoneArray [F x C], with optional index blending and protect (as in RVC).
    private func buildFeatures(_ s: ModelState, params p: EngineParams) {
        let model = s.model
        let C = model.voice.embChannels
        let E = s.phone.count / C
        if s.mixed.count != s.phone.count { s.mixed = [Float](repeating: 0, count: s.phone.count) }
        let M = model.indexNorms?.count ?? 0
        let useIndex = model.indexVectors != nil && p.indexRatio > 0 && M > 0
        let first = min(cfg.skip / 2, E - 1)  // only frames that were not searched before matter
        let Q = E - first
        if useIndex && s.dots.count < Q * M { s.dots = [Float](repeating: 0, count: Q * M) }
        let F = cfg.F
        let protectOn = useIndex && p.protect < 0.5
        let protect = p.protect
        let r = p.indexRatio
        let dst = s.phoneArray.dataPointer.assumingMemoryBound(to: Float.self)
        let f0p = f0
        // Hot loops run on raw pointers taken once (no per-element class property access).
        s.phone.withUnsafeBufferPointer { feats in
            s.mixed.withUnsafeMutableBufferPointer { mixed in
                mixed.baseAddress!.update(from: feats.baseAddress!, count: feats.count)
                if useIndex, let vecsArr = model.indexVectors, let normsArr = model.indexNorms {
                    let k = min(8, M)
                    vecsArr.withUnsafeBufferPointer { vecs in
                        normsArr.withUnsafeBufferPointer { norms in
                            s.dots.withUnsafeMutableBufferPointer { dots in
                                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(Q), Int32(M), Int32(C),
                                            1, feats.baseAddress! + first * C, Int32(C), vecs.baseAddress!, Int32(C),
                                            0, dots.baseAddress!, Int32(M))
                                withUnsafeTemporaryAllocation(of: Float.self, capacity: 2 * k) { tmp in
                                    withUnsafeTemporaryAllocation(of: Int.self, capacity: k) { bestI in
                                        let bestD = tmp.baseAddress!
                                        let w = tmp.baseAddress! + k
                                        for q in 0..<Q {
                                            var xx: Float = 0
                                            vDSP_svesq(feats.baseAddress! + (first + q) * C, 1, &xx, vDSP_Length(C))
                                            // top-k smallest squared L2 distances
                                            var filled = 0
                                            var worst = 0
                                            let row = q * M
                                            func findWorst() -> Int {
                                                var wi = 0
                                                for j in 1..<k where bestD[j] > bestD[wi] { wi = j }
                                                return wi
                                            }
                                            for i in 0..<M {
                                                let dist = max(xx + norms[i] - 2 * dots[row + i], 0)
                                                if filled < k {
                                                    bestD[filled] = dist; bestI[filled] = i; filled += 1
                                                    if filled == k { worst = findWorst() }
                                                } else if dist < bestD[worst] {
                                                    bestD[worst] = dist; bestI[worst] = i
                                                    worst = findWorst()
                                                }
                                            }
                                            var wsum: Float = 0
                                            for j in 0..<k { w[j] = 1 / max(bestD[j] * bestD[j], 1e-12); wsum += w[j] }
                                            let base = (first + q) * C
                                            for c in 0..<C {
                                                var acc: Float = 0
                                                for j in 0..<k { acc += vecs[bestI[j] * C + c] * w[j] }
                                                mixed[base + c] = acc / wsum * r + feats[base + c] * (1 - r)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                // upscale: append last frame, repeat each frame twice, keep F frames
                for t in 0..<F {
                    let e = min(t / 2, E - 1)  // frame E (the appended copy) equals frame E-1
                    let pf: Float = protectOn ? (f0p[t] > 0 ? 1 : protect) : 1
                    for c in 0..<C {
                        let v = mixed[e * C + c]
                        dst[t * C + c] = pf == 1 ? v : v * pf + feats[e * C + c] * (1 - pf)
                    }
                }
            }
        }
    }

    private func decodeF0(_ s: ModelState) {
        let dims = s.model.fcpe.outDims
        let frames = s.latent.count / dims
        let thr = Float(s.model.fcpe.threshold)
        for i in 0..<f0.count { f0[i] = 0 }
        let start = max(frames - cfg.F, 0)  // keep the newest F frames
        s.latent.withUnsafeBufferPointer { values in
            for t in 0..<min(cfg.F, frames) {
                let base = (start + t) * dims
                var maxV: Float = -1, maxI = 0
                for k in 0..<dims where values[base + k] > maxV { maxV = values[base + k]; maxI = k }
                if maxV <= thr { continue }
                var num: Float = 0, den: Float = 0
                for k in max(0, maxI - 4)...min(dims - 1, maxI + 4) {
                    num += s.centTable[k] * values[base + k]
                    den += values[base + k]
                }
                f0[t] = 10 * powf(2, (num / max(den, 1e-9)) / 1200)
            }
        }
    }

    private func sola(gain: Float) {
        var bestOffset = 0
        if cfOut > 0 {
            var best: Float = -.greatestFiniteMagnitude
            seg.withUnsafeBufferPointer { a in
                solaBuffer.withUnsafeBufferPointer { sb in
                    for off in 0...searchOut {
                        var num: Float = 0, energy: Float = 0
                        vDSP_dotpr(a.baseAddress! + off, 1, sb.baseAddress!, 1, &num, vDSP_Length(cfOut))
                        vDSP_svesq(a.baseAddress! + off, 1, &energy, vDSP_Length(cfOut))
                        let score = num / sqrtf(energy + 1e-8)
                        if score > best { best = score; bestOffset = off }
                    }
                }
            }
        }
        for i in 0..<blockOut {
            var v = seg[bestOffset + i]
            if i < cfOut { v = v * fadeIn[i] + solaBuffer[i] * fadeOut[i] }
            out[i] = v * gain
        }
        for i in 0..<cfOut { solaBuffer[i] = seg[bestOffset + blockOut + i] }
        lastOffset = bestOffset
    }

    /// Copies any MLMultiArray (float32/float16/double, any strides) into a dense, reused [Float].
    static func copy(_ a: MLMultiArray, into out: inout [Float]) {
        let n = a.count
        if out.count != n { out = [Float](repeating: 0, count: n) }
        let shape = a.shape.map { $0.intValue }
        let strides = a.strides.map { $0.intValue }
        var dense = true
        var expect = 1
        for d in stride(from: shape.count - 1, through: 0, by: -1) {
            if shape[d] > 1 && strides[d] != expect { dense = false }
            expect *= shape[d]
        }
        // offset of the k-th element in logical (row-major) order
        func offset(_ k: Int) -> Int {
            if dense { return k }
            var rem = k, off = 0
            for d in stride(from: shape.count - 1, through: 0, by: -1) {
                off += (rem % shape[d]) * strides[d]
                rem /= shape[d]
            }
            return off
        }
        out.withUnsafeMutableBufferPointer { o in
            switch a.dataType {
            case .float32:
                let p = a.dataPointer.assumingMemoryBound(to: Float.self)
                if dense {
                    o.baseAddress!.update(from: p, count: n)
                } else {
                    for k in 0..<n { o[k] = p[offset(k)] }
                }
            case .float16:
                let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
                for k in 0..<n { o[k] = Float(p[offset(k)]) }
            case .double:
                let p = a.dataPointer.assumingMemoryBound(to: Double.self)
                for k in 0..<n { o[k] = Float(p[offset(k)]) }
            default:
                for k in 0..<n { o[k] = a[k].floatValue }
            }
        }
    }
}
