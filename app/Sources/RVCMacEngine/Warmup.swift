import RVCMacCore

/// Silence warm-up for a fresh pipeline (prepare, B6). Runs a few inferences on silence so
/// the first real block is not cold (Core ML compiles/caches on the first predictions), then
/// resets the pipeline state. Called off the worker, before the pipeline/state is handed over.
package enum Warmup {
    package static func run(blocks: Int, block16: Int,
                            shouldContinue: () -> Bool = { true },
                            process: (UnsafeBufferPointer<Float>, inout StageTimes) throws -> Void,
                            reset: () -> Void) throws {
        let silence = [Float](repeating: 0, count: block16)
        var times = StageTimes()
        for _ in 0..<blocks {
            // a superseded switch must not burn warm-up inferences
            guard shouldContinue() else { throw CancellationError() }
            _ = try silence.withUnsafeBufferPointer { try process($0, &times) }
        }
        reset()
    }
}