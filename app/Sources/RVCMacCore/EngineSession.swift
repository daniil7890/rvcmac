/// Allows one engine start at a time and decides whether it needs a restart once it has finished.
/// Used from the main actor only.
public struct EngineSession: Sendable {
    public struct Token: Equatable, Sendable {
        fileprivate let id: UInt64
    }

    /// The devices and rates an engine runs on, or the ones currently selected.
    public struct Devices: Equatable, Sendable {
        public var inputUID: String
        public var outputUID: String
        public var inputRate: Double
        public var outputRate: Double

        public init(inputUID: String, outputUID: String, inputRate: Double, outputRate: Double) {
            self.inputUID = inputUID
            self.outputUID = outputUID
            self.inputRate = inputRate
            self.outputRate = outputRate
        }
    }

    private var current: Token?
    private var nextID: UInt64 = 0
    private var pendingDeviceChange = false

    public init() {}

    public var isStarting: Bool { current != nil }

    /// Returns a token for this start, or nil if another start is still running.
    public mutating func begin() -> Token? {
        guard current == nil else { return nil }
        nextID += 1
        let token = Token(id: nextID)
        current = token
        pendingDeviceChange = false
        return token
    }

    /// Records a device event that arrived during a start. Any number of them count as one.
    public mutating func noteDeviceChange() {
        if isStarting { pendingDeviceChange = true }
    }

    /// Ends a start. `started` is nil when no engine came up. Returns true if the caller should restart once.
    @discardableResult
    public mutating func finish(_ token: Token, started: Devices?, current now: Devices) -> Bool {
        guard token == current else { return false }
        current = nil
        defer { pendingDeviceChange = false }
        guard pendingDeviceChange, let started else { return false }
        return started != now
    }
}
