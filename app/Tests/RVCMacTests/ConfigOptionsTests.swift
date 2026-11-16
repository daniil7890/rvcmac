import RVCMacCore
import XCTest

final class ConfigOptionsTests: XCTestCase {
    func testAllValuesArePositiveMultiplesOfTen() {
        for v in LatencyOptions.block + LatencyOptions.extra + LatencyOptions.crossfade {
            XCTAssertGreaterThan(v, 0)
            XCTAssertEqual(v % 10, 0, "converter requires multiples of 10: \(v)")
        }
    }

    func testDefaultsAreExpressibleAndListsAreUnique() {
        // AppState defaults (duplicated as literals: the test target does not depend on RVCMac);
        // a saved value outside the picker tags would silently show an empty selection
        XCTAssertTrue(LatencyOptions.block.contains(250))
        XCTAssertTrue(LatencyOptions.extra.contains(500))
        XCTAssertTrue(LatencyOptions.crossfade.contains(100))
        for list in [LatencyOptions.block, LatencyOptions.extra, LatencyOptions.crossfade] {
            XCTAssertEqual(Set(list).count, list.count, "duplicate picker tags")
            XCTAssertEqual(list, list.sorted(), "picker values must be sorted")
        }
    }

    func testLadderStepsAreExpressible() {
        let ladder: [(block: Int, extra: Int, cf: Int)] = [
            (50, 530, 50),   // A: b50_e530_c50
            (60, 540, 30),   // B': b60_e540_c30
            (50, 550, 30),   // B: b50_e550_c30
            (70, 530, 30),   // reserve: b70_e530_c30
        ]
        for step in ladder {
            XCTAssertTrue(LatencyOptions.block.contains(step.block), "block \(step.block) missing")
            XCTAssertTrue(LatencyOptions.extra.contains(step.extra), "extra \(step.extra) missing")
            XCTAssertTrue(LatencyOptions.crossfade.contains(step.cf), "crossfade \(step.cf) missing")
        }
    }
}