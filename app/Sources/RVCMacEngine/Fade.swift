import Foundation

/// Pure block-boundary transitions (D2–D5 in the pipeline, A2–A3 in the output callback):
/// equal-power sin² fades on caller-owned buffers. The helpers never allocate, so they are
/// safe on the inference worker and inside the RT output callback.
package enum Fade {
    /// Equal-power sin² curve pair of length n: fadeIn goes 0→1, fadeOut 1→0, they sum to 1.
    package static func curves(_ n: Int) -> (fadeIn: [Float], fadeOut: [Float]) {
        guard n > 0 else { return ([], []) }
        let fadeIn = (0..<n).map { i -> Float in
            let t = n > 1 ? Float(i) / Float(n - 1) : 1
            let s = sinf(0.5 * .pi * t)
            return s * s
        }
        return (fadeIn, fadeIn.map { 1 - $0 })
    }

    /// Crossfades the first n samples of `new` with the previous output `old`.
    /// In-place is allowed when `new == out` (each element is read before it is written).
    package static func crossfade(old: UnsafePointer<Float>, new: UnsafePointer<Float>,
                                  into out: UnsafeMutablePointer<Float>, count n: Int,
                                  fadeIn: [Float], fadeOut: [Float]) {
        for i in 0..<n { out[i] = new[i] * fadeIn[i] + old[i] * fadeOut[i] }
    }

    /// Fades the head of `out` (the new signal, already gained) from a constant anchor —
    /// the last heard sample — so the first sample continues the previous block exactly (D2).
    package static func fadeFrom(last: Float, into out: UnsafeMutablePointer<Float>,
                                 count n: Int, fadeIn: [Float], fadeOut: [Float]) {
        for i in 0..<n { out[i] = out[i] * fadeIn[i] + last * fadeOut[i] }
    }

    /// Replaces a block with silence: ramps from the previous last sample down to 0 over
    /// the tail of the fadeOut curve, then zeros (D5).
    package static func silence(from last: Float, into out: UnsafeMutablePointer<Float>,
                                count: Int, ramp: Int, fadeOut: [Float]) {
        let n = min(ramp, count)
        for i in 0..<n { out[i] = last * fadeOut[ramp - n + i] }
        for i in n..<count { out[i] = 0 }
    }

    /// Ramps the gain from `from` to `to` over the first min(ramp, count) samples and holds
    /// `to` afterwards (D4). A constant gain of 1 is a no-op, keeping the hot path untouched.
    package static func gain(from: Float, to: Float, into out: UnsafeMutablePointer<Float>,
                             count: Int, ramp: Int, fadeIn: [Float]) {
        if from == to {
            if to != 1 { for i in 0..<count { out[i] *= to } }
            return
        }
        let n = min(ramp, count)
        for i in 0..<n { out[i] *= from + (to - from) * fadeIn[i] }
        if to != 1 { for i in n..<count { out[i] *= to } }
    }

    /// Ramps the tail of a partial buffer down to zero on underrun (A2). The segment is
    /// normalized so its first sample keeps the previous amplitude: no step at the callback
    /// boundary when the partial buffer is shorter than the ramp.
    package static func rampDownTail(_ buf: UnsafeMutablePointer<Float>, got: Int, ramp: Int, fadeOut: [Float]) {
        let n = min(got, ramp)
        guard n > 0 else { return }
        let g0 = fadeOut[ramp - n]
        let inv: Float = g0 > 0 ? 1 / g0 : 1
        for j in 0..<n { buf[got - n + j] *= fadeOut[ramp - n + j] * inv }
    }

    /// Ramps the head of a buffer up from silence on resume after re-prefill (A2).
    /// `left` is the number of ramp samples still to play; returns how many were consumed.
    package static func rampUpHead(_ buf: UnsafeMutablePointer<Float>, got: Int, left: Int, ramp: Int, fadeIn: [Float]) -> Int {
        let n = min(left, got)
        let base = ramp - left
        for j in 0..<n { buf[j] *= fadeIn[base + j] }
        return n
    }

    /// Whether any sample is NaN or Inf (D5).
    package static func hasNonFinite(_ p: UnsafePointer<Float>, count: Int) -> Bool {
        for i in 0..<count where !p[i].isFinite { return true }
        return false
    }
}