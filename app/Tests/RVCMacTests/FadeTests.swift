import Foundation
import RVCMacEngine
import XCTest

/// Smoothness is checked numerically: the largest difference between neighbouring samples.
private func maxStep(_ p: UnsafePointer<Float>, count: Int) -> Float {
    var m: Float = 0
    for i in 1..<count { m = max(m, abs(p[i] - p[i - 1])) }
    return m
}

final class FadeTests: XCTestCase {
    private let ramp = 240   // 5 ms at 48 kHz

    func testCurvesEndpointsAndComplement() {
        let (fi, fo) = Fade.curves(ramp)
        XCTAssertEqual(fi.count, ramp)
        XCTAssertEqual(fi[0], 0)
        XCTAssertEqual(fi[ramp - 1], 1)
        XCTAssertEqual(fo[0], 1)
        XCTAssertEqual(fo[ramp - 1], 0)
        for i in 0..<ramp { XCTAssertEqual(fi[i] + fo[i], 1, accuracy: 1e-6) }
        for i in 1..<ramp { XCTAssertGreaterThanOrEqual(fi[i], fi[i - 1]) }
        XCTAssertTrue(Fade.curves(0).fadeIn.isEmpty)
    }

    func testCrossfadeIsSmoothAndEndsAtNew() {
        let (fi, fo) = Fade.curves(ramp)
        var old = [Float](repeating: 1, count: ramp)
        var new = [Float](repeating: 0.5, count: ramp)
        var out = [Float](repeating: 0, count: ramp)
        old.withUnsafeBufferPointer { o in
            new.withUnsafeBufferPointer { n in
                out.withUnsafeMutableBufferPointer { u in
                    Fade.crossfade(old: o.baseAddress!, new: n.baseAddress!, into: u.baseAddress!,
                                     count: ramp, fadeIn: fi, fadeOut: fo)
                }
            }
        }
        XCTAssertEqual(out[0], 1)              // starts exactly at the old signal
        XCTAssertEqual(out[ramp - 1], 0.5)     // ends exactly at the new signal
        XCTAssertLessThan(maxStep(out, count: ramp), 0.01)
    }

    func testCrossfadeClampedToBlockCompletesWithinBlock() {
        // D3: configured 150 ms crossfade, 100 ms block at 48 kHz -> applied length is the block
        let block = 4800
        let configured = 7200
        let n = min(configured, block)
        let (fi, fo) = Fade.curves(n)
        var old = [Float](repeating: 1, count: n)
        var new = [Float](repeating: 0.25, count: n)
        var out = [Float](repeating: 0, count: n)
        old.withUnsafeBufferPointer { o in
            new.withUnsafeBufferPointer { u in
                out.withUnsafeMutableBufferPointer { r in
                    Fade.crossfade(old: o.baseAddress!, new: u.baseAddress!, into: r.baseAddress!,
                                     count: n, fadeIn: fi, fadeOut: fo)
                }
            }
        }
        XCTAssertEqual(out[n - 1], 0.25)       // fully on the new signal within the block
        XCTAssertLessThan(maxStep(out, count: n), 0.01)
    }

    func testFadeFromAnchorContinuesLastSample() {
        let (fi, fo) = Fade.curves(ramp)
        var out = [Float](repeating: 0.5, count: ramp)
        out.withUnsafeMutableBufferPointer { u in
            Fade.fadeFrom(last: 0.8, into: u.baseAddress!, count: ramp, fadeIn: fi, fadeOut: fo)
        }
        XCTAssertEqual(out[0], 0.8)            // exactly the last heard sample, no backward jump
        XCTAssertEqual(out[ramp - 1], 0.5)     // fully on the new signal within the fade
        XCTAssertLessThan(maxStep(out, count: ramp), 0.01)
    }

    func testSilenceRampsFromLastSample() {
        let (_, fo) = Fade.curves(ramp)
        let count = 4800
        var out = [Float](repeating: 9, count: count)
        out.withUnsafeMutableBufferPointer { u in
            Fade.silence(from: 0.8, into: u.baseAddress!, count: count, ramp: ramp, fadeOut: fo)
        }
        XCTAssertEqual(out[0], 0.8)            // no jump from the previous block
        XCTAssertEqual(out[ramp - 1], 0)
        for i in ramp..<count { XCTAssertEqual(out[i], 0) }
        XCTAssertLessThan(maxStep(out, count: count), 0.01)
    }

    func testGainRampHasNoBoundaryJump() {
        let (fi, _) = Fade.curves(ramp)
        let count = 4800
        var out = [Float](repeating: 1, count: count)
        out.withUnsafeMutableBufferPointer { u in
            Fade.gain(from: 1, to: 0.5, into: u.baseAddress!, count: count, ramp: ramp, fadeIn: fi)
        }
        XCTAssertEqual(out[0], 1)              // starts at the previous gain
        XCTAssertEqual(out[ramp - 1], 0.5, accuracy: 1e-6)
        XCTAssertEqual(out[count - 1], 0.5)
        XCTAssertLessThan(maxStep(out, count: count), 0.005)
    }

    func testGainConstantOneIsNoOp() {
        let (fi, _) = Fade.curves(ramp)
        var out: [Float] = (0..<100).map { Float($0) / 100 }
        let before = out
        let n = out.count
        out.withUnsafeMutableBufferPointer { u in
            Fade.gain(from: 1, to: 1, into: u.baseAddress!, count: n, ramp: ramp, fadeIn: fi)
        }
        XCTAssertEqual(out, before)
    }

    func testHasNonFinite() {
        let clean: [Float] = [0, 0.5, -0.5]
        XCTAssertFalse(clean.withUnsafeBufferPointer { Fade.hasNonFinite($0.baseAddress!, count: $0.count) })
        let nan: [Float] = [0, .nan, 0.5]
        XCTAssertTrue(nan.withUnsafeBufferPointer { Fade.hasNonFinite($0.baseAddress!, count: $0.count) })
        let inf: [Float] = [0, .infinity]
        XCTAssertTrue(inf.withUnsafeBufferPointer { Fade.hasNonFinite($0.baseAddress!, count: $0.count) })
    }

    func testUnderrunRampDownEndsAtZero() {
        let (_, fo) = Fade.curves(ramp)
        let got = 100   // partial buffer, shorter than the ramp
        var buf = [Float](repeating: 1, count: got)
        buf.withUnsafeMutableBufferPointer { u in
            Fade.rampDownTail(u.baseAddress!, got: got, ramp: ramp, fadeOut: fo)
        }
        XCTAssertEqual(buf[0], 1)              // no step at the callback boundary
        XCTAssertEqual(buf[got - 1], 0)        // the cut to silence is ramped, not a step
        for i in 1..<got { XCTAssertLessThanOrEqual(buf[i], buf[i - 1]) }
        XCTAssertLessThan(maxStep(buf, count: got), 0.05)
    }

    func testUnderrunRampKeepsBoundarySampleOfPartialBuffer() {
        // the previous callback ended mid-splice at an arbitrary value; the ramp must
        // continue from it exactly, whatever the blend produced
        let (_, fo) = Fade.curves(ramp)
        let got = 37
        var buf: [Float] = (0..<got).map { 0.3 + Float($0) / 1000 }
        let first = buf[0]
        buf.withUnsafeMutableBufferPointer { u in
            Fade.rampDownTail(u.baseAddress!, got: got, ramp: ramp, fadeOut: fo)
        }
        XCTAssertEqual(buf[0], first, accuracy: 1e-6)
        XCTAssertEqual(buf[got - 1], 0)
        // full-length partial buffer: unchanged behaviour (curve starts at 1)
        var full = [Float](repeating: 0.7, count: ramp)
        full.withUnsafeMutableBufferPointer { u in
            Fade.rampDownTail(u.baseAddress!, got: ramp, ramp: ramp, fadeOut: fo)
        }
        XCTAssertEqual(full[0], 0.7)
        XCTAssertEqual(full[ramp - 1], 0)
    }

    func testResumeRampUpSpansBuffers() {
        let (fi, _) = Fade.curves(ramp)
        var first = [Float](repeating: 1, count: 100)
        let used1 = first.withUnsafeMutableBufferPointer { u in
            Fade.rampUpHead(u.baseAddress!, got: 100, left: ramp, ramp: ramp, fadeIn: fi)
        }
        XCTAssertEqual(used1, 100)
        XCTAssertEqual(first[0], 0)            // resumes from silence
        var second = [Float](repeating: 1, count: 200)
        let left = ramp - used1
        let used2 = second.withUnsafeMutableBufferPointer { u in
            Fade.rampUpHead(u.baseAddress!, got: 200, left: left, ramp: ramp, fadeIn: fi)
        }
        XCTAssertEqual(used2, left)
        XCTAssertEqual(second[used2 - 1], 1, accuracy: 1e-6)   // ramp completed
        XCTAssertEqual(second[used2], 1)                        // rest untouched
        // continuity across the callback boundary
        XCTAssertEqual(abs(second[0] - first[99]), fi[100] - fi[99], accuracy: 1e-6)
        var joined = first + second
        XCTAssertLessThan(maxStep(&joined, count: joined.count), 0.02)
    }

    func testTrimSpliceWithPartialTail() {
        // A3: the discarded region can be shorter than the ramp; the scratch prefix is
        // padded with the first discarded sample so the full-length fade still starts
        // exactly at the old signal.
        let (fi, fo) = Fade.curves(ramp)
        let keep = 100
        var old = [Float](repeating: 0, count: ramp)
        for i in 0..<keep { old[ramp - keep + i] = Float(i) / Float(keep) }
        let firstOld = old[ramp - keep]
        for j in 0..<(ramp - keep) { old[j] = firstOld }
        var out = [Float](repeating: 0.5, count: ramp)
        old.withUnsafeBufferPointer { o in
            out.withUnsafeMutableBufferPointer { u in
                Fade.crossfade(old: o.baseAddress!, new: u.baseAddress!, into: u.baseAddress!,
                                 count: ramp, fadeIn: fi, fadeOut: fo)
            }
        }
        XCTAssertEqual(out[0], firstOld)                  // continues the old signal, no step
        XCTAssertEqual(out[ramp - 1], 0.5, accuracy: 1e-6)
        XCTAssertLessThan(maxStep(out, count: ramp), 0.05)
    }

    func testTrimSpliceIsSmooth() {
        // A3: the discarded tail and the new region disagree in phase; the crossfade must
        // remove the step. 50 Hz sines at 48 kHz, phase jump of pi/2 at the splice.
        let (fi, fo) = Fade.curves(ramp)
        var old = [Float](repeating: 0, count: ramp)
        var new = [Float](repeating: 0, count: ramp)
        for i in 0..<ramp {
            let t = Double(i) / 48000
            old[i] = Float(sin(2 * Double.pi * 50 * t))
            new[i] = Float(sin(2 * Double.pi * 50 * t + Double.pi / 2))
        }
        let rawJump = abs(new[0] - old[0])
        XCTAssertGreaterThan(rawJump, 0.9)     // without the crossfade this is a click
        var out = [Float](repeating: 0, count: ramp)
        old.withUnsafeBufferPointer { o in
            new.withUnsafeBufferPointer { n in
                out.withUnsafeMutableBufferPointer { u in
                    Fade.crossfade(old: o.baseAddress!, new: n.baseAddress!, into: u.baseAddress!,
                                     count: ramp, fadeIn: fi, fadeOut: fo)
                }
            }
        }
        XCTAssertEqual(out[0], old[0])         // continues the old signal, no step
        XCTAssertLessThan(maxStep(out, count: ramp), 0.05)
    }
}