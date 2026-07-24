import XCTest
@testable import ODEKit

final class DiagnosticsTests: XCTestCase {
    private func tempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-diag-test-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTrimDropsOldestKeepsNewestLines() throws {
        let lines = (0..<1000).map { "line-\($0)" }.joined(separator: "\n") + "\n"
        let url = try tempFile(lines)
        Diagnostics.trimLog(at: url, capBytes: 4000, keepBytes: 2000)
        let kept = try String(contentsOf: url, encoding: .utf8)
        XCTAssertLessThanOrEqual(kept.utf8.count, 2000)
        XCTAssertFalse(kept.contains("line-0\n"), "oldest lines must be dropped")
        XCTAssertTrue(kept.hasSuffix("line-999\n"), "newest line must survive")
        XCTAssertTrue(kept.hasPrefix("line-"), "must cut on a line boundary")
    }

    func testTrimLeavesSmallLogUntouched() throws {
        let contents = "a few\nshort lines\n"
        let url = try tempFile(contents)
        Diagnostics.trimLog(at: url, capBytes: 4000, keepBytes: 2000)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), contents)
    }

    func testTrimMissingFileIsHarmless() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ode-diag-test-missing-\(UUID().uuidString).log")
        Diagnostics.trimLog(at: missing, capBytes: 100, keepBytes: 50)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
