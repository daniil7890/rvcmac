import Foundation
import os
import RVCMacCore

/// Releases models and pipelines on a background queue (B5). Core ML deallocation is
/// slow; it must not run on the inference worker or under a lock the UI reads. Objects
/// are retained until the queue runs the release, so a fast stop→start may briefly hold
/// two model sets; the worker never pays for the deallocation.
package final class ModelReleaser {
    private let queue: DispatchQueue
    private let logLock = OSAllocatedUnfairLock(initialState: (@Sendable (String) -> Void)?.none)
    private let inflight = OSAllocatedUnfairLock(initialState: 0)

    /// Drain diagnostics sink: accepted/released object counts. The sink adds the timestamp.
    package var log: (@Sendable (String) -> Void)? {
        get { logLock.withLock { $0 } }
        set { logLock.withLock { $0 = newValue } }
    }

    package init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Takes ownership of the objects; they are deallocated on the background queue.
    package func release(_ objects: AnyObject...) {
        let n = objects.count
        let log = self.log
        let queued = inflight.withLock { $0 += n; return $0 }
        log?(trf("ModelReleaser: принято %@ объектов, в очереди %@.", "\(n)", "\(queued)"))
        queue.async { [inflight] in
            _ = objects
            let left = inflight.withLock { $0 -= n; return $0 }
            log?(trf("ModelReleaser: освобождено %@ объектов, в очереди %@.", "\(n)", "\(left)"))
        }
    }
}