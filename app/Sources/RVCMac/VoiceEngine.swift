import Accelerate
import CoreAudio
import CoreML
import Foundation
import os

struct EngineParams {
    var pitch: Int = 0          // semitones
    var gateDB: Float = -60     // input gate threshold
    var gain: Float = 1.0       // output gain
    var bypass = false          // pass input straight through (for checking routing)
    var indexRatio: Float = 0.5 // how much retrieved index features replace the input features
    var protect: Float = 0.33   // keep original features on unvoiced frames (0.5 = off)
}

struct EngineStats {
    var processMs: Double = 0
    var blockMs: Double = 0
    var inputDB: Float = -120
    var underruns = 0
    var gated = false
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

final class VoiceEngine {
    private let io = AudioIO()
    private let model: LoadedVoice
    private var thread: Thread?
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let paramsLock = OSAllocatedUnfairLock(initialState: EngineParams())
    var onStats: ((EngineStats) -> Void)?
    var onError: ((String) -> Void)?

    // sizes
    private let cfg: LatencyConfig
    private let block16: Int
    private let window: Int        // N
    private var outRate = 48000.0
    private var blockOut = 0, cfOut = 0, searchOut = 0, segOut = 0

    // buffers
    private var win: [Float]
    private var acc16: [Float] = []
    private var solaBuffer: [Float] = []
    private var fadeIn: [Float] = []
    private var fadeOut: [Float] = []
    private var rng = Gaussian()
    private var centTable: [Float] = []

    // Core ML inputs (reused)
    private let audioArray: MLMultiArray
    private let pitchArray: MLMultiArray
    private let noiseArray: MLMultiArray
    private let sineArray: MLMultiArray
    private let phoneArray: MLMultiArray

    private var inResampler: Resampler?
    private var outResampler: Resampler?
    private var bypassResampler: Resampler?

    init(model: LoadedVoice) throws {
        self.model = model
        cfg = model.config
        block16 = cfg.blockF * 160
        window = cfg.N
        win = [Float](repeating: 0, count: cfg.N)
        audioArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.N)], dataType: .float32)
        pitchArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.F)], dataType: .int32)
        noiseArray = try MLMultiArray(shape: [1, NSNumber(value: model.interChannels), NSNumber(value: cfg.F - cfg.flowHead)], dataType: .float32)
        sineArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.R * model.upp), 1], dataType: .float32)
        phoneArray = try MLMultiArray(shape: [1, NSNumber(value: cfg.F), NSNumber(value: model.voice.embChannels)], dataType: .float32)
        let m = model.fcpe
        let c0 = 1200 * log2(m.f0Min / 10), c1 = 1200 * log2(m.f0Max / 10)
        centTable = (0..<m.outDims).map { Float(c0 + (c1 - c0) * Double($0) / Double(m.outDims - 1)) }
    }

    var params: EngineParams {
        get { paramsLock.withLock { $0 } }
        set { paramsLock.withLock { $0 = newValue } }
    }

    func start(input: AudioDeviceID, output: AudioDeviceID) throws {
        try io.start(input: input, output: output)
        outRate = io.outputRate
        let perFrame = Int(outRate) / 100
        blockOut = cfg.blockF * perFrame
        cfOut = cfg.crossfadeF * perFrame
        searchOut = cfg.solaF * perFrame
        segOut = cfg.R * perFrame
        io.outputPrefill = blockOut / 2
        solaBuffer = [Float](repeating: 0, count: cfOut)
        fadeIn = (0..<cfOut).map { i in
            let t = cfOut > 1 ? Float(i) / Float(cfOut - 1) : 1
            let s = sinf(0.5 * .pi * t)
            return s * s
        }
        fadeOut = fadeIn.map { 1 - $0 }
        inResampler = Resampler(from: io.inputRate, to: 16000)
        outResampler = Resampler(from: Double(model.voice.sr), to: outRate)
        bypassResampler = Resampler(from: 16000, to: outRate)
        win = [Float](repeating: 0, count: window)
        acc16 = []
        running.withLock { $0 = true }
        let t = Thread { [weak self] in self?.loop() }
        t.qualityOfService = .userInteractive
        t.name = "RVCMac.inference"
        thread = t
        t.start()
    }

    func stop() {
        running.withLock { $0 = false }
        io.stop()
        thread = nil
    }

    private var isRunning: Bool { running.withLock { $0 } }

    // MARK: - Worker loop

    private func loop() {
        let tmp = UnsafeMutablePointer<Float>.allocate(capacity: 48000)
        defer { tmp.deallocate() }
        var stats = EngineStats()
        var lastReport = Date()
        var procTimes: [Double] = []
        while isRunning {
            let n = io.inputFIFO.read(into: tmp, count: 48000)
            if n > 0, let rs = inResampler {
                acc16.append(contentsOf: rs.stream(UnsafeBufferPointer(start: tmp, count: n)))
            }
            if acc16.count >= block16 {
                // if we fell far behind, skip old audio instead of growing latency forever
                if acc16.count > block16 * 4 { acc16.removeFirst(acc16.count - block16 * 2) }
                let block = Array(acc16[0..<block16])
                acc16.removeFirst(block16)
                let t0 = DispatchTime.now().uptimeNanoseconds
                do {
                    let (out, db, gated) = try process(block)
                    io.outputFIFO.write(out)
                    io.outputFIFO.trim(keep: blockOut * 3)
                    stats.inputDB = db
                    stats.gated = gated
                } catch {
                    onError?("Inference error: \(error.localizedDescription)")
                    running.withLock { $0 = false }
                    break
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
                procTimes.append(ms)
                if Date().timeIntervalSince(lastReport) > 0.3 {
                    stats.processMs = procTimes.max() ?? ms
                    stats.blockMs = Double(cfg.blockMs)
                    procTimes.removeAll()
                    lastReport = Date()
                    onStats?(stats)
                }
            } else {
                usleep(1500)
            }
        }
    }

    // MARK: - One block

    private func process(_ block: [Float]) throws -> ([Float], Float, Bool) {
        let p = params
        // slide window
        win.removeFirst(block16)
        win.append(contentsOf: block)

        // input level over the newest block + crossfade
        let lvlCount = min(window, block16 + cfg.crossfadeF * 160)
        var ms: Float = 0
        win.withUnsafeBufferPointer { b in
            vDSP_measqv(b.baseAddress! + (window - lvlCount), 1, &ms, vDSP_Length(lvlCount))
        }
        let db = 10 * log10f(ms + 1e-12)

        if p.bypass {
            let out = block.withUnsafeBufferPointer { bypassResampler?.stream($0) ?? [] }
            return (out.map { $0 * p.gain }, db, false)
        }
        if db < p.gateDB {
            return ([Float](repeating: 0, count: blockOut), db, true)
        }

        // 1. ContentVec
        win.withUnsafeBufferPointer { b in
            audioArray.dataPointer.assumingMemoryBound(to: Float.self).update(from: b.baseAddress!, count: window)
        }
        let embOut = try model.embedder.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray]))
        guard let phone = embOut.featureValue(for: model.voice.embOutput)?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 1, userInfo: [NSLocalizedDescriptionKey: "embedder output missing"])
        }

        // 2. FCPE -> f0 per 10 ms frame
        let pitchOut = try model.pitchModel.prediction(from: try MLDictionaryFeatureProvider(dictionary: ["audio": audioArray]))
        guard let latent = pitchOut.featureValue(for: "latent")?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "fcpe output missing"])
        }
        var f0 = decodeF0(latent)  // F values
        let shift = powf(2, Float(p.pitch) / 12)
        for i in 0..<f0.count { f0[i] *= shift }

        // 3. coarse pitch for the encoder
        let melMin: Float = 1127 * logf(1 + 50 / 700), melMax: Float = 1127 * logf(1 + 1100 / 700)
        let pitchPtr = pitchArray.dataPointer.assumingMemoryBound(to: Int32.self)
        for i in 0..<cfg.F {
            var mel = 1127 * logf(1 + f0[i] / 700)
            mel = (mel - melMin) * 254 / (melMax - melMin) + 1
            pitchPtr[i] = Int32(max(1, min(255, mel.rounded())))
        }

        // 3b. features: index retrieval on 20 ms frames, x2 upscale to 10 ms frames, protect
        buildFeatures(floats(phone), f0: f0, params: p)

        // 4. NSF excitation for the decoded frames (same maths as RVC SineGen)
        let upp = model.upp
        let sr = Double(model.voice.sr)
        let sinePtr = sineArray.dataPointer.assumingMemoryBound(to: Float.self)
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

        // 5. prior noise
        let noisePtr = noiseArray.dataPointer.assumingMemoryBound(to: Float.self)
        for i in 0..<noiseArray.count { noisePtr[i] = rng.next() }

        // 6. synthesizer
        let synthIn = try MLDictionaryFeatureProvider(dictionary: [
            "phone": phoneArray, "pitch": pitchArray, "noise": noiseArray, "sine": sineArray,
        ])
        let synthOut = try model.synth.prediction(from: synthIn)
        guard let audio = synthOut.featureValue(for: "audio")?.multiArrayValue else {
            throw NSError(domain: "RVCMac", code: 3, userInfo: [NSLocalizedDescriptionKey: "synth output missing"])
        }
        let modelAudio = floats(audio)

        // 7. to output rate, SOLA crossfade
        let seg = outResampler!.segment(modelAudio, outCount: segOut)
        return (sola(seg, gain: p.gain), db, false)
    }

    /// ContentVec frames [E x C] -> phoneArray [F x C], with optional index blending and protect (as in RVC).
    private func buildFeatures(_ feats: [Float], f0: [Float], params p: EngineParams) {
        let C = model.voice.embChannels
        let E = feats.count / C
        var mixed = feats
        let useIndex = model.indexVectors != nil && p.indexRatio > 0
        if useIndex, let vecs = model.indexVectors, let norms = model.indexNorms {
            let first = min(cfg.skip / 2, E - 1)  // only frames that were not searched before matter
            let Q = E - first
            let M = norms.count
            let k = min(8, M)
            var dots = [Float](repeating: 0, count: Q * M)
            feats.withUnsafeBufferPointer { x in
                vecs.withUnsafeBufferPointer { y in
                    dots.withUnsafeMutableBufferPointer { d in
                        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(Q), Int32(M), Int32(C),
                                    1, x.baseAddress! + first * C, Int32(C), y.baseAddress!, Int32(C),
                                    0, d.baseAddress!, Int32(M))
                    }
                }
            }
            var bestD = [Float](repeating: 0, count: k)
            var bestI = [Int](repeating: 0, count: k)
            let r = p.indexRatio
            for q in 0..<Q {
                var xx: Float = 0
                feats.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + (first + q) * C, 1, &xx, vDSP_Length(C)) }
                // top-k smallest squared L2 distances
                var filled = 0
                var worst = 0
                let row = q * M
                for i in 0..<M {
                    let dist = max(xx + norms[i] - 2 * dots[row + i], 0)
                    if filled < k {
                        bestD[filled] = dist; bestI[filled] = i; filled += 1
                        if filled == k { worst = bestD.indices.max { bestD[$0] < bestD[$1] }! }
                    } else if dist < bestD[worst] {
                        bestD[worst] = dist; bestI[worst] = i
                        worst = bestD.indices.max { bestD[$0] < bestD[$1] }!
                    }
                }
                var wsum: Float = 0
                var w = [Float](repeating: 0, count: k)
                for j in 0..<k { w[j] = 1 / max(bestD[j] * bestD[j], 1e-12); wsum += w[j] }
                let base = (first + q) * C
                for c in 0..<C {
                    var acc: Float = 0
                    for j in 0..<k { acc += vecs[bestI[j] * C + c] * w[j] }
                    mixed[base + c] = acc / wsum * r + feats[base + c] * (1 - r)
                }
            }
        }
        // upscale: append last frame, repeat each frame twice, keep F frames
        let dst = phoneArray.dataPointer.assumingMemoryBound(to: Float.self)
        let protectOn = useIndex && p.protect < 0.5
        for t in 0..<cfg.F {
            let e = min(t / 2, E - 1)  // frame E (the appended copy) equals frame E-1
            let pf: Float = protectOn ? (f0[t] > 0 ? 1 : p.protect) : 1
            for c in 0..<C {
                let v = mixed[e * C + c]
                dst[t * C + c] = pf == 1 ? v : v * pf + feats[e * C + c] * (1 - pf)
            }
        }
    }

    private func decodeF0(_ latent: MLMultiArray) -> [Float] {
        let values = floats(latent)
        let dims = model.fcpe.outDims
        let frames = values.count / dims
        let thr = Float(model.fcpe.threshold)
        var f0 = [Float](repeating: 0, count: cfg.F)
        let start = max(frames - cfg.F, 0)  // keep the newest F frames
        for t in 0..<min(cfg.F, frames) {
            let base = (start + t) * dims
            var maxV: Float = -1, maxI = 0
            for k in 0..<dims where values[base + k] > maxV { maxV = values[base + k]; maxI = k }
            if maxV <= thr { continue }
            var num: Float = 0, den: Float = 0
            for k in max(0, maxI - 4)...min(dims - 1, maxI + 4) {
                num += centTable[k] * values[base + k]
                den += values[base + k]
            }
            f0[t] = 10 * powf(2, (num / max(den, 1e-9)) / 1200)
        }
        return f0
    }

    private func sola(_ audio: [Float], gain: Float) -> [Float] {
        var bestOffset = 0
        if cfOut > 0 {
            var best: Float = -.greatestFiniteMagnitude
            audio.withUnsafeBufferPointer { a in
                solaBuffer.withUnsafeBufferPointer { s in
                    for off in 0...searchOut {
                        var num: Float = 0, energy: Float = 0
                        vDSP_dotpr(a.baseAddress! + off, 1, s.baseAddress!, 1, &num, vDSP_Length(cfOut))
                        vDSP_svesq(a.baseAddress! + off, 1, &energy, vDSP_Length(cfOut))
                        let score = num / sqrtf(energy + 1e-8)
                        if score > best { best = score; bestOffset = off }
                    }
                }
            }
        }
        var out = [Float](repeating: 0, count: blockOut)
        for i in 0..<blockOut {
            var v = audio[bestOffset + i]
            if i < cfOut { v = v * fadeIn[i] + solaBuffer[i] * fadeOut[i] }
            out[i] = v * gain
        }
        for i in 0..<cfOut { solaBuffer[i] = audio[bestOffset + blockOut + i] }
        return out
    }

    /// Copies any MLMultiArray (float32/float16/double, any strides) into a dense [Float].
    private func floats(_ a: MLMultiArray) -> [Float] {
        let n = a.count
        var out = [Float](repeating: 0, count: n)
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
        switch a.dataType {
        case .float32:
            let p = a.dataPointer.assumingMemoryBound(to: Float.self)
            if dense {
                out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: n) }
            } else {
                for k in 0..<n { out[k] = p[offset(k)] }
            }
        case .float16:
            let p = a.dataPointer.assumingMemoryBound(to: Float16.self)
            for k in 0..<n { out[k] = Float(p[offset(k)]) }
        case .double:
            let p = a.dataPointer.assumingMemoryBound(to: Double.self)
            for k in 0..<n { out[k] = Float(p[offset(k)]) }
        default:
            for k in 0..<n { out[k] = a[k].floatValue }
        }
        return out
    }
}
