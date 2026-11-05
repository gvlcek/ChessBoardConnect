import XCTest
@testable import ChessBoardConnect

final class DiagnosticTests: XCTestCase {
    @MainActor
    func testDiscoveryIncludesUnregisteredAndUnnamedDevicesAndUpdatesDuplicates() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        diagnostics.scan()
        let id = UUID()
        transport.onEvent?(.device(device(id: id, name: "ChessUp")))
        transport.onEvent?(.device(device(id: UUID(), name: "Unnamed device")))
        transport.onEvent?(.device(device(id: id, name: "ChessUp", rssi: -42)))
        XCTAssertEqual(diagnostics.devices.count, 2)
        XCTAssertEqual(diagnostics.devices[0].rssi, -42)
        XCTAssertNil(DriverRegistry.standard.makeDriver(for: "ChessUp"))
        try diagnostics.inspect(id)
        XCTAssertEqual(transport.inspectedIDs, [id])
    }
    @MainActor
    func testSelectionGuardsAndScanCannotInterruptAnInspection() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        XCTAssertThrowsError(try diagnostics.inspect(UUID()))
        let id = UUID()
        transport.onEvent?(.device(device(id: id, name: "ChessUp", connectable: false)))
        XCTAssertThrowsError(try diagnostics.inspect(id)) { XCTAssertEqual($0 as? BLEDiagnosticError, .notConnectable) }
        XCTAssertTrue(transport.inspectedIDs.isEmpty)
        try diagnostics.selectForReport(id)
        XCTAssertEqual(diagnostics.selectedDevice?.isConnectable, false)
        XCTAssertTrue(transport.inspectedIDs.isEmpty, "Advertisement export must not open a connection")
        transport.onEvent?(.device(device(id: id, name: "ChessUp")))
        try diagnostics.inspect(id)
        XCTAssertThrowsError(try diagnostics.inspect(id)) { XCTAssertEqual($0 as? BLEDiagnosticError, .busy) }
        diagnostics.scan()
        XCTAssertEqual(transport.scanCount, 0)
        XCTAssertEqual(diagnostics.selectedDevice?.id, id)
    }
    @MainActor
    func testPartialDiscoveryAndDisconnectPreserveTheCollectedSnapshot() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        let id = UUID()
        transport.onEvent?(.device(device(id: id, name: "ChessUp")))
        try diagnostics.inspect(id)
        let snapshot = [BLEDiagnosticService(uuid: "test-service", isPrimary: true,
            characteristics: [BLEDiagnosticCharacteristic(uuid: "test-characteristic", properties: ["notify"])])]
        transport.onEvent?(.services(snapshot, complete: false))
        XCTAssertFalse(diagnostics.inspectionCompleted)
        transport.onEvent?(.services(snapshot, complete: true))
        transport.onEvent?(.state(.inspected, "Complete"))
        diagnostics.disconnect()
        XCTAssertFalse(diagnostics.state.connectionActive)
        XCTAssertTrue(diagnostics.inspectionCompleted)
        XCTAssertEqual(diagnostics.services, snapshot)
        diagnostics.scan()
        XCTAssertTrue(diagnostics.services.isEmpty)
        XCTAssertNil(diagnostics.selectedDevice)
        XCTAssertFalse(diagnostics.inspectionCompleted)
    }
    @MainActor
    func testFailureNeverClaimsCompleteInspectionAndLogsAreBounded() {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        transport.onEvent?(.services([], complete: true))
        for _ in 0..<220 { transport.onEvent?(.state(.failed("Unavailable"), "Unavailable")) }
        XCTAssertFalse(diagnostics.inspectionCompleted)
        XCTAssertEqual(diagnostics.logs.count, 200)
        XCTAssertFalse(diagnostics.state.connectionActive)
    }
    private func device(id: UUID, name: String, rssi: Int = -60, connectable: Bool? = nil) -> BLEDiagnosticDevice {
        BLEDiagnosticDevice(id: id, name: name, localName: name, advertisedServices: [], rssi: rssi, isConnectable: connectable)
    }
}

@MainActor
private final class FakeInspectionTransport: BLEInspectionTransport {
    var onEvent: ((BLEInspectionEvent) -> Void)?
    var inspectedIDs: [UUID] = []
    var scanCount = 0
    func scan() { scanCount += 1; onEvent?(.state(.scanning, "Scanning")) }
    func stopScan() { onEvent?(.state(.scanComplete, "Scan complete")) }
    func inspect(_ id: UUID) { inspectedIDs.append(id); onEvent?(.state(.connecting, "Connecting")) }
    func disconnect() { onEvent?(.state(.disconnected, "Disconnected")) }
}
