import XCTest
@testable import RVCMac

final class ConverterSetupTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rvcmac-certifi-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: tmp)
    }

    private func makeBundle(pythonDir: String) throws -> String {
        let dir = tmp.appendingPathComponent("lib/\(pythonDir)/site-packages/certifi")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pem = dir.appendingPathComponent("cacert.pem")
        try Data("dummy CA bundle".utf8).write(to: pem)
        return pem.path
    }

    func testGlobFindsBundleInFakeVenv() throws {
        let expected = try makeBundle(pythonDir: "python3.12")
        XCTAssertEqual(ConverterSetup.certifiBundle(venv: tmp), expected)
    }

    func testGlobSkipsPythonDirsWithoutCertifi() throws {
        let empty = tmp.appendingPathComponent("lib/python3.11/site-packages")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let expected = try makeBundle(pythonDir: "python3.12")
        XCTAssertEqual(ConverterSetup.certifiBundle(venv: tmp), expected)
    }

    func testMissingBundleLeavesEnvUntouched() {
        XCTAssertNil(ConverterSetup.certifiBundle(venv: tmp))
        var env = ["PATH": "/usr/bin"]
        ConverterSetup.applyCertifi(to: &env, venv: tmp)
        XCTAssertEqual(env, ["PATH": "/usr/bin"])
    }

    func testApplySetsBothVarsAndInheritedValuesWin() throws {
        let expected = try makeBundle(pythonDir: "python3.12")
        var env: [String: String] = [:]
        ConverterSetup.applyCertifi(to: &env, venv: tmp)
        XCTAssertEqual(env["SSL_CERT_FILE"], expected)
        XCTAssertEqual(env["REQUESTS_CA_BUNDLE"], expected)

        var inherited = ["SSL_CERT_FILE": "/corp/ca.pem"]
        ConverterSetup.applyCertifi(to: &inherited, venv: tmp)
        XCTAssertEqual(inherited["SSL_CERT_FILE"], "/corp/ca.pem")
        XCTAssertEqual(inherited["REQUESTS_CA_BUNDLE"], expected)
    }
}