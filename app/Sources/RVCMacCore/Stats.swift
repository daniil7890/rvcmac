import Foundation

/// Summary of a series of measurements. Percentiles use linear interpolation between
/// closest ranks (same as numpy's default), so p50 of [1, 2, 3, 4] is 2.5.
public struct Distribution: Codable, Hashable, Sendable {
    public var count: Int
    public var min: Double
    public var max: Double
    public var mean: Double
    public var p50: Double
    public var p95: Double
    public var p99: Double

    public init(count: Int, min: Double, max: Double, mean: Double, p50: Double, p95: Double, p99: Double) {
        self.count = count
        self.min = min
        self.max = max
        self.mean = mean
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
    }

    public static let empty = Distribution(count: 0, min: 0, max: 0, mean: 0, p50: 0, p95: 0, p99: 0)

    /// Non-finite values (NaN = "not measured") are ignored.
    public static func of<S: Sequence>(_ values: S) -> Distribution where S.Element == Double {
        var v = values.filter { $0.isFinite }
        guard !v.isEmpty else { return .empty }
        v.sort()
        let sum = v.reduce(0, +)
        return Distribution(count: v.count, min: v[0], max: v[v.count - 1], mean: sum / Double(v.count),
                            p50: percentile(sorted: v, 0.50), p95: percentile(sorted: v, 0.95), p99: percentile(sorted: v, 0.99))
    }

    /// q in 0...1, `sorted` must be ascending and non-empty.
    public static func percentile(sorted v: [Double], _ q: Double) -> Double {
        precondition(!v.isEmpty)
        if v.count == 1 { return v[0] }
        let pos = Swift.min(Swift.max(q, 0), 1) * Double(v.count - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Swift.min(lo + 1, v.count - 1)
        let frac = pos - Double(lo)
        return v[lo] + (v[hi] - v[lo]) * frac
    }
}
