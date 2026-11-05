import Foundation
import XCTest

final class ReportExportTests: XCTestCase {
    @MainActor
    func testFrozenSnapshotBoundedEventsAndUniqueFiles() async throws {
        var liveLogs = (0..<220).map { "Event \($0)" }
        let snapshot = ReportSnapshot(fields: ["Board: Test", "Status: Connected"], logs: liveLogs)
        liveLogs.removeAll()
        let first = try await ReportExport.prepare(snapshot)
        let second = try await ReportExport.prepare(snapshot)
        XCTAssertNotEqual(first, second)
        let text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Board: Test\nStatus: Connected\n\nEvent 20\n"))
        XCTAssertTrue(text.hasSuffix("Event 219"))
        XCTAssertFalse(text.contains("Event 19\n"))
        await ReportExport.remove(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        await ReportExport.remove(second)
    }
    func testExportFailureIsReportedAndCleanupDoesNotRemoveUnrelatedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: directory)
        do {
            _ = try await ReportExport.prepare(ReportSnapshot(fields: [], logs: []), directory: directory)
            XCTFail("A file cannot be used as an export directory")
        } catch { }
        await ReportExport.remove(directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        try FileManager.default.removeItem(at: directory)
    }
}
