import XCTest

/// Runs converter/test_convert.py (FCPE pinning: quarantine instead of delete,
/// OKADA verification, explicit confirmation). The Python side stubs torch/numpy,
/// so a bare python3 is enough; skipped when none is available.
final class FcpePinningTests: XCTestCase {
    func testPythonPinningSuite() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        try XCTSkipIf(!FileManager.default.isExecutableFile(atPath: python.path), "python3 unavailable")
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // RVCMacTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // app
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("converter/test_convert.py")
        try XCTSkipIf(!FileManager.default.fileExists(atPath: script.path), "converter/test_convert.py not found")
        let p = Process()
        p.executableURL = python
        p.arguments = [script.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, String(decoding: data, as: UTF8.self))
    }
}