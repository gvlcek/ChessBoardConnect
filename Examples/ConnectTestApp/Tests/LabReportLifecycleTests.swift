import Foundation
import Combine
import XCTest
import ChessBoardConnect

final class LabReportLifecycleTests: XCTestCase {
    private let metadata = ReportMetadata(appVersion: "Test", build: "42", device: "Test iPhone")

    @MainActor
    func testExportFreezesStateAndDismissalCleansUpWithoutDisconnecting() async throws {
        let started = XCTestExpectation(description: "Export started")
        let removed = XCTestExpectation(description: "Report removed")
        let exporter = ControlledLabExporter(started: started, removed: removed)
        let client = ExportTestClient()
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: client, exporter: exporter,
                                           now: { Date(timeIntervalSince1970: 0) })
        client.emit(.status("Snapshot status"))
        client.emit(.logs(["Before export"]))
        model.firmware = "Firmware A"
        model.exportReport(metadata: metadata)
        model.exportReport(metadata: metadata)
        await wait(for: started)
        XCTAssertTrue(model.exporting)
        client.emit(.status("Later status"))
        client.emit(.logs(["After export"]))
        model.firmware = "Firmware B"
        let snapshots = await exporter.snapshots
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(try XCTUnwrap(snapshots.first).fields.contains("Status: Snapshot status"))
        XCTAssertTrue(try XCTUnwrap(snapshots.first).fields.contains("Firmware: Firmware A"))
        XCTAssertEqual(snapshots.first?.logs, ["Before export"])

        let presented = XCTestExpectation(description: "Report presented")
        let subscription = model.$exportedReport.compactMap { $0 }.sink { _ in presented.fulfill() }
        let url = URL(fileURLWithPath: "/tmp/frozen-report.txt")
        await exporter.succeed(url)
        await wait(for: presented)
        XCTAssertEqual(model.exportedReport?.url, url)
        XCTAssertFalse(model.exporting)
        XCTAssertFalse(model.canExport)
        model.reportDismissed()
        await wait(for: removed)
        let removedURLs = await exporter.removedURLs
        XCTAssertEqual(removedURLs, [url])
        XCTAssertTrue(model.canExport)
        XCTAssertNil(model.exportedReport)
        XCTAssertEqual(client.disconnectCount, 0)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testLeavingDuringExportPreventsPresentationAndCleansLateFile() async {
        let started = XCTestExpectation(description: "Export started")
        let removed = XCTestExpectation(description: "Cancelled export cleaned")
        let exporter = ControlledLabExporter(started: started, removed: removed)
        let client = ExportTestClient()
        let model = ConnectionLabViewModel(configuration: .chessUp, client: client, exporter: exporter)
        model.exportReport(metadata: metadata)
        await wait(for: started)
        model.stop()
        XCTAssertFalse(model.exporting)
        XCTAssertEqual(client.disconnectCount, 1)
        let url = URL(fileURLWithPath: "/tmp/late-report.txt")
        await exporter.succeed(url)
        await wait(for: removed)
        XCTAssertNil(model.exportedReport)
        XCTAssertNil(model.errorMessage)
        let removedURLs = await exporter.removedURLs
        XCTAssertEqual(removedURLs, [url])
    }

    @MainActor
    func testExportFailureShowsAnErrorAndAllowsRetry() async {
        let started = XCTestExpectation(description: "Export started")
        let exporter = ControlledLabExporter(started: started)
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: ExportTestClient(), exporter: exporter)
        let failed = XCTestExpectation(description: "Error published")
        let subscription = model.$errorMessage.compactMap { $0 }.sink { _ in failed.fulfill() }
        model.exportReport(metadata: metadata)
        await wait(for: started)
        await exporter.fail()
        await wait(for: failed)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.exporting)
        XCTAssertTrue(model.canExport)
        XCTAssertNil(model.exportedReport)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testStoppingWithPresentedReportRemovesIt() async {
        let started = XCTestExpectation(description: "Export started")
        let removed = XCTestExpectation(description: "Report cleaned on stop")
        let exporter = ControlledLabExporter(started: started, removed: removed)
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: ExportTestClient(), exporter: exporter)
        let presented = XCTestExpectation(description: "Report presented")
        let subscription = model.$exportedReport.compactMap { $0 }.sink { _ in presented.fulfill() }
        model.exportReport(metadata: metadata)
        await wait(for: started)
        await exporter.succeed(URL(fileURLWithPath: "/tmp/presented-report.txt"))
        await wait(for: presented)
        model.stop()
        model.reportDismissed()
        await wait(for: removed)
        let removedURLs = await exporter.removedURLs
        XCTAssertEqual(removedURLs.count, 1)
        XCTAssertNil(model.exportedReport)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testLateCancelledExportCannotReplaceOrFinishANewerExport() async {
        let firstStarted = XCTestExpectation(description: "First export started")
        let nextStarted = XCTestExpectation(description: "New export started")
        let removed = XCTestExpectation(description: "Old file removed")
        let exporter = ControlledLabExporter(started: firstStarted, removed: removed, laterStarted: nextStarted)
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: ExportTestClient(), exporter: exporter)
        model.exportReport(metadata: metadata)
        await wait(for: firstStarted)
        model.stop()
        model.exportReport(metadata: metadata)
        await wait(for: nextStarted)
        let oldURL = URL(fileURLWithPath: "/tmp/old-report.txt")
        await exporter.succeed(oldURL)
        await wait(for: removed)
        XCTAssertTrue(model.exporting, "The cancelled task must not finish the new task's state")
        XCTAssertNil(model.exportedReport)
        let presented = XCTestExpectation(description: "Only new report presented")
        let subscription = model.$exportedReport.compactMap { $0 }.sink { _ in presented.fulfill() }
        let newURL = URL(fileURLWithPath: "/tmp/new-report.txt")
        await exporter.succeed(newURL)
        await wait(for: presented)
        XCTAssertEqual(model.exportedReport?.url, newURL)
        XCTAssertFalse(model.exporting)
        model.reportDismissed()
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    private func wait(for expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}

private actor ControlledLabExporter: LabReportExporting {
    let started: XCTestExpectation
    let removed: XCTestExpectation?
    let laterStarted: XCTestExpectation?
    private(set) var snapshots: [ReportSnapshot] = []
    private(set) var removedURLs: [URL] = []
    private var pending: [CheckedContinuation<URL, Error>] = []

    init(started: XCTestExpectation, removed: XCTestExpectation? = nil, laterStarted: XCTestExpectation? = nil) {
        self.started = started
        self.removed = removed
        self.laterStarted = laterStarted
    }
    func prepare(_ snapshot: ReportSnapshot) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            snapshots.append(snapshot)
            pending.append(continuation)
            if snapshots.count == 1 { started.fulfill() } else { laterStarted?.fulfill() }
        }
    }
    func succeed(_ url: URL) { if !pending.isEmpty { pending.removeFirst().resume(returning: url) } }
    func fail() { if !pending.isEmpty { pending.removeFirst().resume(throwing: CocoaError(.fileWriteNoPermission)) } }
    func remove(_ url: URL) { removedURLs.append(url); removed?.fulfill() }
}

@MainActor
private final class ExportTestClient: LabBoardClient {
    private let subject = PassthroughSubject<LabBoardEvent, Never>()
    var events: AnyPublisher<LabBoardEvent, Never> { subject.eraseToAnyPublisher() }
    var disconnectCount = 0
    func emit(_ event: LabBoardEvent) { subject.send(event) }
    func scan() {}
    func findConnectedBoards(namePrefix: String?) {}
    func stopScan() {}
    func connect(_ id: UUID) throws {}
    func disconnect() { disconnectCount += 1 }
    func reconnect() throws {}
    func send(_ command: BoardCommand) throws {}
    func clearLogs() {}
}
