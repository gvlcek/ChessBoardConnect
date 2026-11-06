import Foundation
import Combine
import XCTest
import ChessBoardConnect

final class ConnectionLabViewModelTests: XCTestCase {
    @MainActor
    func testDiscoveryUsesConfigurationIncludingFutureModels() {
        let client = StubLabBoardClient()
        let nearby = ConnectionLabViewModel(configuration: .nearbyBoards, client: client)
        nearby.search()
        XCTAssertEqual(client.scanCount, 1)
        let chessUp = ConnectionLabViewModel(configuration: .chessUp, client: client)
        chessUp.search()
        XCTAssertEqual(client.lookups, ["ChessUp"])

        let future = LabConfiguration(id: "future", label: "Future board", title: "Future Test",
                                      discovery: .systemConnected(namePrefix: "Another Brand"),
                                      searchTitle: "Find board", instructions: "Connect first.")
        let another = ConnectionLabViewModel(configuration: future, client: client)
        another.search()
        XCTAssertEqual(client.lookups, ["ChessUp", "Another Brand"])
        client.emit(.scanning(true))
        another.search()
        XCTAssertEqual(client.lookups.count, 2)
        client.emit(.scanning(false))
        client.emit(.state(.connecting))
        another.search()
        XCTAssertFalse(another.canSearch)
        XCTAssertEqual(client.lookups.count, 2)
    }

    @MainActor
    func testControlsFollowCapabilitiesRatherThanDiscoveryPreset() {
        let client = StubLabBoardClient()
        let model = ConnectionLabViewModel(configuration: .chessUp, client: client)
        client.emit(.capabilities([.readPosition, .controlLights]))
        XCTAssertFalse(model.supports(.readPosition))
        model.refresh()
        XCTAssertTrue(client.commands.isEmpty)
        XCTAssertEqual(model.errorMessage, ConnectError.notConnected.errorDescription)
        client.emit(.ready(true))
        XCTAssertTrue(model.supports(.readPosition))
        XCTAssertTrue(model.supports(.controlLights))
        XCTAssertFalse(model.supports(.sendMove))
        model.sendMove()
        XCTAssertTrue(client.commands.isEmpty)
        XCTAssertEqual(model.errorMessage, ConnectError.unsupportedCapability.errorDescription)
        client.emit(.ready(false))
        XCTAssertEqual(model.capabilityDescription(.readPosition), "Not connected")
    }

    @MainActor
    func testLightsRejectWholeInvalidInputAndNormalizeValidSquares() {
        let client = StubLabBoardClient()
        let model = readyModel(client, capabilities: [.controlLights])
        for input in ["", "e2 z9", "a1, h9", "e２"] {
            model.lightSquares = input
            model.turnLightsOn()
            XCTAssertNotNil(model.errorMessage)
        }
        XCTAssertTrue(client.commands.isEmpty)
        model.lightSquares = "E2, e4 a1"
        model.turnLightsOn()
        XCTAssertNil(model.errorMessage, "A successful retry clears the previous action error")
        guard case .setLights(let squares) = client.commands.last else { return XCTFail("Missing lights") }
        XCTAssertEqual(squares, [52, 36, 56])
        model.turnLightsOff()
        guard case .setLights(let off) = client.commands.last else { return XCTFail("Missing lights off") }
        XCTAssertEqual(off, [])
    }

    @MainActor
    func testMoveValidationAndFENForwardingDoNotInventBoardConfirmation() throws {
        let client = StubLabBoardClient()
        let model = readyModel(client, capabilities: [.sendMove, .loadPosition])
        model.moveFrom = "E7"
        model.moveTo = "E5"
        model.sendMove()
        guard case .sendMove(let move) = client.commands.last else { return XCTFail("Missing move") }
        XCTAssertEqual(move, try BoardMove(from: 12, to: 28))
        XCTAssertTrue(model.commandResult.contains("Queued"))
        XCTAssertNil(model.board.lastMove)
        model.moveFrom = "a7"
        model.moveTo = "a8"
        model.promotion = "q"
        model.sendMove()
        guard case .sendMove(let promoted) = client.commands.last else { return XCTFail("Missing promotion") }
        XCTAssertEqual(promoted.promotion, "q")
        let count = client.commands.count
        for input in ["qq", "k"] {
            model.promotion = input
            model.sendMove()
        }
        model.promotion = ""
        model.moveTo = "a7"
        model.sendMove()
        model.moveFrom = "z9"
        model.sendMove()
        XCTAssertEqual(client.commands.count, count)
        model.fen = "A user-provided FEN: the driver validates protocol constraints"
        model.loadPosition()
        guard case .loadPosition(let fen) = client.commands.last else { return XCTFail("Missing FEN") }
        XCTAssertEqual(fen, model.fen)
        XCTAssertNil(model.board.position)
        client.failure = .sessionNotInitialized
        model.moveFrom = "e2"
        model.moveTo = "e4"
        model.sendMove()
        XCTAssertEqual(model.errorMessage, ConnectError.sessionNotInitialized.errorDescription)
        XCTAssertEqual(model.commandResult, "The action failed.")
    }

    @MainActor
    func testIncomingReadingsMovesAndSessionReset() throws {
        let client = StubLabBoardClient()
        let date = Date(timeIntervalSince1970: 123)
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: client, now: { date })
        client.emit(.position(.initial))
        client.emit(.position(.initial))
        XCTAssertEqual(model.readingCount, 2, "Repeated sensor readings must still be counted")
        XCTAssertEqual(model.lastReading, date)
        client.emit(.position(nil))
        XCTAssertNil(model.board.position)
        XCTAssertNil(model.lastReading)
        XCTAssertEqual(model.readingCount, 2)
        client.emit(.state(.connecting))
        XCTAssertEqual(model.readingCount, 0)
        let move = try BoardMove(from: 52, to: 36)
        client.emit(.move(move))
        XCTAssertEqual(model.board.lastMove, move)
        XCTAssertEqual(model.lastMoveDescription, "e2 → e4")
        client.emit(.move(nil))
        XCTAssertNil(model.lastMoveDescription)
    }

    @MainActor
    func testSelectionErrorsAndForegroundRefresh() {
        let client = StubLabBoardClient()
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: client)
        let device = BoardDevice(id: UUID(), name: "Test board", rssi: -42, capabilities: [.readPosition])
        client.emit(.devices([device]))
        XCTAssertEqual(model.board.devices, [device])
        client.failure = .deviceNotFound
        model.select(device)
        XCTAssertEqual(model.selectedName, "Not selected")
        XCTAssertNotNil(model.errorMessage)
        client.failure = nil
        model.select(device)
        XCTAssertEqual(client.selected, device.id)
        XCTAssertEqual(model.selectedName, "Test board")
        model.sceneDidBecomeActive()
        XCTAssertTrue(client.commands.isEmpty)
        client.emit(.capabilities([.readPosition]))
        client.emit(.ready(true))
        model.sceneDidBecomeActive()
        guard case .requestPosition = client.commands.last else { return XCTFail("No refresh") }
        client.emit(.ready(false))
        model.sceneDidBecomeActive()
        XCTAssertEqual(client.commands.count, 1)
    }

    @MainActor
    func testClearLogsKeepsReadingsAndStopReleasesTheSession() {
        let client = StubLabBoardClient()
        let model = readyModel(client, capabilities: [.readPosition])
        client.emit(.position(.initial))
        client.emit(.logs(["RX packet"]))
        model.clearLogs()
        XCTAssertTrue(model.board.logs.isEmpty)
        XCTAssertEqual(model.board.position, .initial)
        XCTAssertEqual(model.readingCount, 1)
        XCTAssertEqual(client.disconnectCount, 0)
        model.reconnect()
        XCTAssertEqual(client.reconnectCount, 1)
        model.stop()
        XCTAssertEqual(client.stopScanCount, 1)
        XCTAssertEqual(client.disconnectCount, 1)
        XCTAssertFalse(model.board.ready)
        XCTAssertNil(model.board.position)
    }

    @MainActor
    func testLiveAdapterPublishesInitialStateAndDisconnectWithoutBluetooth() {
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: LiveLabBoardClient())
        XCTAssertEqual(model.board.connection, .idle)
        XCTAssertEqual(model.board.status, "Bluetooth not started")
        XCTAssertTrue(model.board.logs.isEmpty)
        model.disconnect()
        XCTAssertEqual(model.board.connection, .disconnected)
        XCTAssertEqual(model.board.status, "Disconnected")
        XCTAssertFalse(model.board.ready)
        XCTAssertFalse(model.board.connectedOrConnecting)
    }

    @MainActor
    private func readyModel(_ client: StubLabBoardClient, capabilities: BoardCapabilities) -> ConnectionLabViewModel {
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: client)
        client.emit(.state(.connected))
        client.emit(.capabilities(capabilities))
        client.emit(.ready(true))
        return model
    }
}

@MainActor
private final class StubLabBoardClient: LabBoardClient {
    private let subject = PassthroughSubject<LabBoardEvent, Never>()
    var events: AnyPublisher<LabBoardEvent, Never> { subject.eraseToAnyPublisher() }
    var scanCount = 0
    var lookups: [String?] = []
    var stopScanCount = 0
    var disconnectCount = 0
    var reconnectCount = 0
    var selected: UUID?
    var commands: [BoardCommand] = []
    var failure: ConnectError?
    func emit(_ event: LabBoardEvent) { subject.send(event) }
    func scan() { scanCount += 1 }
    func findConnectedBoards(namePrefix: String?) { lookups.append(namePrefix) }
    func stopScan() { stopScanCount += 1 }
    func connect(_ id: UUID) throws { if let failure { throw failure }; selected = id }
    func disconnect() {
        disconnectCount += 1
        emit(.position(nil)); emit(.ready(false)); emit(.state(.disconnected))
    }
    func reconnect() throws { if let failure { throw failure }; reconnectCount += 1 }
    func send(_ command: BoardCommand) throws { if let failure { throw failure }; commands.append(command) }
    func clearLogs() { emit(.logs([])) }
}
