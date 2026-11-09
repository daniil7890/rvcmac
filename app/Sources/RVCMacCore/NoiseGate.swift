/// Decides, once per block, whether the input gate is open.
/// It opens at the threshold, closes only below `threshold - hysteresisDB`, and stays open for `holdBlocks` more blocks.
public struct NoiseGate: Sendable {
    public private(set) var isOpen = false
    private var holdLeft = 0

    public init() {}

    public mutating func reset() {
        isOpen = false
        holdLeft = 0
    }

    @discardableResult
    public mutating func update(db: Float, threshold: Float, hysteresisDB: Float, holdBlocks: Int) -> Bool {
        if db >= threshold || (isOpen && db >= threshold - hysteresisDB) {
            isOpen = true
            holdLeft = holdBlocks
        } else if isOpen {
            if holdLeft > 0 { holdLeft -= 1 } else { isOpen = false }
        }
        return isOpen
    }
}
