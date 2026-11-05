import XCTest
@testable import ChessBoardConnect

final class DiagnosticTests: XCTestCase {
    @MainActor
    func testDiscoveryIncludesUnregisteredAndUnnamedDevicesAndUpdatesDuplicates() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        diagnostics.scan()
        let id = UUID()
        transport.onEvent?(.device(device(id: id, name: "Future board")))
        transport.onEvent?(.device(device(id: UUID(), name: "Unnamed device")))
        transport.onEvent?(.device(device(id: id, name: "Future board", rssi: -42)))
        XCTAssertEqual(diagnostics.devices.count, 2)
        XCTAssertEqual(diagnostics.devices[0].rssi, -42)
        XCTAssertEqual(diagnostics.devices[0].source, .advertisement)
        XCTAssertNil(DriverRegistry.standard.makeDriver(for: "Future board"))
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
        diagnostics.checkConnectedDevices()
        XCTAssertEqual(transport.scanCount, 0)
        XCTAssertEqual(transport.connectedLookupCount, 0)
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
    @MainActor
    func testSystemConnectedLookupIsSeparateFromAdvertisingAndStillNeedsLocalInspection() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport)
        let oldID = UUID(), connectedID = UUID()
        transport.onEvent?(.device(device(id: oldID, name: "Previous scan result")))
        diagnostics.checkConnectedDevices()
        XCTAssertEqual(transport.connectedLookupCount, 1)
        XCTAssertEqual(transport.scanCount, 0)
        XCTAssertTrue(diagnostics.devices.isEmpty)
        transport.onEvent?(.device(BLEDiagnosticDevice(id: connectedID, name: "ChessUp", localName: nil,
            advertisedServices: [], rssi: 127, isConnectable: nil, source: .systemConnection)))
        XCTAssertEqual(diagnostics.devices.first?.source, .systemConnection)
        XCTAssertTrue(diagnostics.devices[0].advertisedServices.isEmpty, "Lookup results must not invent advertisement data")
        XCTAssertFalse(diagnostics.inspectionCompleted, "System connectivity alone does not prove a completed GATT inspection")
        XCTAssertTrue(transport.inspectedIDs.isEmpty)
        try diagnostics.inspect(connectedID)
        XCTAssertEqual(transport.inspectedIDs, [connectedID], "A system-connected peripheral still needs a local connection")
    }
    @MainActor
    func testNamePrefixFiltersBothSourcesWithoutPinningAPeripheralIdentifier() throws {
        let transport = FakeInspectionTransport()
        let diagnostics = BoardDiagnostics(transport: transport, namePrefix: "ChessUp")
        diagnostics.checkConnectedDevices()
        let connectedID = UUID()
        let unrelatedID = UUID()
        for (id, name) in [(connectedID, "ChessUp"), (unrelatedID, "Other UART device")] {
            transport.onEvent?(.device(BLEDiagnosticDevice(id: id, name: name, localName: nil,
                advertisedServices: [], rssi: 127, isConnectable: nil, source: .systemConnection)))
        }
        XCTAssertEqual(diagnostics.devices.map(\.id), [connectedID])
        XCTAssertTrue(transport.inspectedIDs.isEmpty, "Finding a matching name must not connect automatically")
        XCTAssertThrowsError(try diagnostics.inspect(unrelatedID)) { XCTAssertEqual($0 as? BLEDiagnosticError, .unknownDevice) }
        try diagnostics.inspect(connectedID)
        XCTAssertEqual(transport.inspectedIDs, [connectedID])
        diagnostics.disconnect()

        diagnostics.scan()
        let advertisedID = UUID()
        let localNameID = UUID()
        transport.onEvent?(.device(device(id: advertisedID, name: "chessup 2")))
        transport.onEvent?(.device(device(id: advertisedID, name: "chessup 2", rssi: -42)))
        transport.onEvent?(.device(BLEDiagnosticDevice(id: localNameID, name: "Unnamed device", localName: "CHESSUP",
            advertisedServices: [], rssi: -60, isConnectable: true)))
        transport.onEvent?(.device(device(id: UUID(), name: "Unnamed device")))
        transport.onEvent?(.device(device(id: UUID(), name: "Not ChessUp")))
        XCTAssertEqual(diagnostics.devices.map(\.id), [advertisedID, localNameID])
        XCTAssertEqual(diagnostics.devices[0].rssi, -42)
        diagnostics.stopScan()
        try diagnostics.inspect(advertisedID)
        XCTAssertEqual(transport.inspectedIDs, [connectedID, advertisedID], "New discoveries use their current iOS identifiers")
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
    var connectedLookupCount = 0
    func scan() { scanCount += 1; onEvent?(.state(.scanning, "Scanning")) }
    func stopScan() { onEvent?(.state(.scanComplete, "Scan complete")) }
    func checkConnectedDevices() { connectedLookupCount += 1; onEvent?(.state(.scanComplete, "System lookup complete")) }
    func inspect(_ id: UUID) { inspectedIDs.append(id); onEvent?(.state(.connecting, "Connecting")) }
    func disconnect() { onEvent?(.state(.disconnected, "Disconnected")) }
}
