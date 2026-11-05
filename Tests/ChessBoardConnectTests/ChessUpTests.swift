import XCTest
@testable import ChessBoardConnect

final class ChessUpTests: XCTestCase {
    private let fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    private func receive(_ bytes: [UInt8], driver: inout ChessUpDriver) throws -> [DriverEvent] {
        try driver.receive(Data(bytes), characteristic: ChessUpDriver.notify)
    }
    private func initializedDriver() throws -> ChessUpDriver {
        var driver = ChessUpDriver()
        _ = try driver.prepare(.loadPosition(fen))
        _ = try receive([0xb1], driver: &driver)
        _ = try receive([0x24], driver: &driver)
        return driver
    }
    func testExplicitSessionWaitsForFENAckBeforeSettingsAndSettingsAckBeforeMoves() throws {
        var driver = ChessUpDriver()
        XCTAssertTrue(driver.initialCommands.isEmpty, "Connecting alone must not start a game")
        XCTAssertFalse(driver.capabilities.contains(.readPosition))
        XCTAssertTrue(driver.capabilities.contains(.receiveMoves))
        let move = try BoardMove(from: 52, to: 36)
        XCTAssertThrowsError(try driver.prepare(.sendMove(move))) { XCTAssertEqual($0 as? ConnectError, .sessionNotInitialized) }
        let packets = try driver.prepare(.loadPosition(fen))
        XCTAssertEqual(packets.first, Data([0x64]))
        XCTAssertEqual(packets.count, 2)
        XCTAssertTrue(driver.commandPending)
        XCTAssertTrue(try receive([0x24], driver: &driver).isEmpty, "Out-of-order settings ack must not unlock the session")
        XCTAssertThrowsError(try driver.prepare(.sendMove(move)))
        let events = try receive([0xb1], driver: &driver)
        guard case .write(let settings) = events.last else { return XCTFail("Missing settings") }
        XCTAssertEqual(settings, Data([0xb9, 5, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0]))
        XCTAssertTrue(driver.commandPending)
        _ = try receive([0x24], driver: &driver)
        XCTAssertFalse(driver.commandPending)
        XCTAssertEqual(try driver.prepare(.sendMove(move)), [Data([0x99, 12, 28])])
        XCTAssertThrowsError(try driver.prepare(.sendMove(move))) { XCTAssertEqual($0 as? ConnectError, .busy) }
        _ = try receive([0x22], driver: &driver)
        XCTAssertFalse(driver.commandPending)
    }
    func testFENUsesBinaryCountersAndRejectsInvalidInputWithoutChangingSession() throws {
        let packet = try ChessUpDriver.encodePosition("8/8/8/8/8/8/8/8 b - e3 255 513")
        let payload = Array("8/8/8/8/8/8/8/8 b - e3 ".utf8) + [255, 2, 1]
        XCTAssertEqual(packet, Data([0x66, UInt8(payload.count)] + payload))
        var driver = try initializedDriver()
        for bad in ["8/8", "8/8/8/8/8/8/8/8 w - - 256 1", "8/8/8/8/8/8/8/8 w - - 0 0", "8/8/8/8/8/8/8/8 x - - 0 1", "8/8/8/8/8/8/8/8 w KK - 0 1"] {
            XCTAssertThrowsError(try driver.prepare(.loadPosition(bad)))
            XCTAssertFalse(driver.commandPending)
        }
    }
    func testReceivedMoveCoordinatesAndAcknowledgment() throws {
        var driver = try initializedDriver()
        let events = try receive([0xa3, 0x35, 4, 1, 4, 3], driver: &driver)
        guard case .write(let ack) = events.first, case .move(let move) = events.last else { return XCTFail("Missing move or ack") }
        XCTAssertEqual(ack, Data([0x21]))
        XCTAssertEqual(move, try BoardMove(from: 52, to: 36))
        for square in [0, 7, 56, 63] { XCTAssertEqual(Int(ChessUpDriver.wireIndex(square)), square ^ 56) }
        XCTAssertThrowsError(try receive([0xa3, 0x35, 9, 1, 4, 3], driver: &driver))
        XCTAssertThrowsError(try receive([0xa3, 0x35, 4], driver: &driver))
        XCTAssertTrue(try receive([0xb8, 2], driver: &driver).isEmpty)
    }
    func testOutgoingPromotionWaitsForMoveAcknowledgment() throws {
        var driver = try initializedDriver()
        _ = try driver.prepare(.sendMove(BoardMove(from: 8, to: 0, promotion: "n")))
        let events = try receive([0x22], driver: &driver)
        guard case .write(let promotion) = events.first else { return XCTFail("Missing promotion command") }
        XCTAssertEqual(promotion, Data([0x97, 2]))
        XCTAssertTrue(driver.commandPending)
        _ = try receive([0x23], driver: &driver)
        XCTAssertFalse(driver.commandPending)
    }
    func testReceivedPromotionUpdatesMoveAndAcknowledgesChoice() throws {
        var driver = try initializedDriver()
        XCTAssertThrowsError(try receive([0x97, 4], driver: &driver))
        _ = try receive([0xa3, 0x35, 0, 6, 0, 7], driver: &driver)
        let events = try receive([0x97, 4], driver: &driver)
        guard case .write(let ack) = events.first, case .move(let move) = events.last else { return XCTFail("Missing promotion") }
        XCTAssertEqual(ack, Data([0x23]))
        XCTAssertEqual(move, try BoardMove(from: 8, to: 0, promotion: "q"))
    }
    func testDuplicateMoveResponseMustMatchThePendingCoordinates() throws {
        var driver = try initializedDriver()
        _ = try driver.prepare(.sendMove(BoardMove(from: 52, to: 36)))
        XCTAssertThrowsError(try receive([0x26, 0x99, 0, 1, 0, 11, 28], driver: &driver))
        XCTAssertTrue(driver.commandPending)
        _ = try receive([0x26, 0x99, 0, 1, 0, 12, 28], driver: &driver)
        XCTAssertFalse(driver.commandPending)
    }
    func testBatchPreflightRejectsFENBeforeCommittingTheResetOrDriverState() throws {
        let original = ChessUpDriver()
        XCTAssertThrowsError(try DriverCommands.prepare(.loadPosition(fen), driver: original, maximumLength: 1)) {
            XCTAssertEqual($0 as? ConnectError, .commandTooLarge)
        }
        XCTAssertFalse(original.commandPending)
        var unchanged = original
        XCTAssertTrue(try receive([0xb1], driver: &unchanged).isEmpty)
        let prepared = try DriverCommands.prepare(.loadPosition(fen), driver: original, maximumLength: 512)
        XCTAssertEqual(prepared.packets.count, 2)
        XCTAssertEqual(prepared.packets[0], Data([0x64]))
        XCTAssertTrue(prepared.driver.commandPending)
        XCTAssertFalse(original.commandPending)
    }

}
