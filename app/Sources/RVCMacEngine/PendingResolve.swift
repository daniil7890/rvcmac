/// Ordering guard for pending latency resolution (telemetry). The output clock must be
/// read before the trim counter: a trim that lands between the two reads republishes the
/// clock past the dropped samples while pending entries still refer to them, so the entries
/// must be discarded and the iteration skipped.
package enum PendingResolve {
    package enum Decision {
        case resolve(position: UInt64, hostTime: UInt64)
        case discard
        case wait
    }

    package static func decide(clock: (position: UInt64, hostTime: UInt64)?, trims: Int, lastTrims: Int) -> Decision {
        guard let clock else { return .wait }
        if trims != lastTrims { return .discard }
        return .resolve(position: clock.position, hostTime: clock.hostTime)
    }
}