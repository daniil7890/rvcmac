import Foundation

/// Releases models and pipelines on a background queue (B5). Core ML deallocation is
/// slow; it must not run on the inference worker or under a lock the UI reads. Objects
/// are retained until the queue runs the release, so a fast stop→start may briefly hold
/// two model sets; the worker never pays for the deallocation.
package final class ModelReleaser {
    private let queue: DispatchQueue

    package init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    /// Takes ownership of the objects; they are deallocated on the background queue.
    package func release(_ objects: AnyObject...) {
        queue.async { _ = objects }
    }
}