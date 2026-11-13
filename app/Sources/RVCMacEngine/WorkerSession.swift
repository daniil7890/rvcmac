import Foundation
import os

/// Lifecycle of the inference worker (C2). Each start() begins a session with its own
/// token and completion signal: the worker runs only while its token is current, and its
/// exit signal is private to the session. A late exit from an old session can therefore
/// neither keep running into a new session nor satisfy the new session's stop().
/// Main thread only, except `isCurrent` and `end(token:)`, which the worker calls.
package final class WorkerSession {
    private let state = OSAllocatedUnfairLock(initialState: (running: false, token: UInt64(0)))
    private var done: DispatchSemaphore?

    package init() {}

    /// Begins a new session. The previous worker, if any, must already be joined.
    package func begin() -> (token: UInt64, done: DispatchSemaphore) {
        let done = DispatchSemaphore(value: 0)
        self.done = done
        let token = state.withLock { s -> UInt64 in
            s.running = true
            s.token += 1
            return s.token
        }
        return (token, done)
    }

    /// Whether this session's worker may keep running.
    package func isCurrent(_ token: UInt64) -> Bool {
        state.withLock { $0.running && $0.token == token }
    }

    /// Asks the worker to exit at the next block boundary.
    package func end() {
        state.withLock { $0.running = false }
    }

    /// Worker-side exit on error: ends only its own session, never a newer one.
    package func end(token: UInt64) {
        state.withLock { if $0.token == token { $0.running = false } }
    }

    /// Waits until the worker signals its exit. An exit slower than `timeout` is reported
    /// via `onSlow`, but the join still completes: returning with the worker alive would
    /// let it write into rings that the next start() resets (C2). A worker that never
    /// exits blocks the caller forever, so every worker exit path must signal.
    package func join(timeout: DispatchTimeInterval = .seconds(3), onSlow: () -> Void = {}) {
        guard let done else { return }
        self.done = nil
        if done.wait(timeout: .now() + timeout) == .timedOut {
            onSlow()
            done.wait()
        }
    }
}