import XCTest
@testable import ChessBoardConnect
import Foundation
import Combine

final class ConnectTests: XCTestCase {
    @MainActor
    func testRejectsCommandsUntilConnected() throws {
        let connect = BoardConnect()
        XCTAssertEqual(connect.state, .idle)
        XCTAssertNil(connect.position)
        XCTAssertTrue(connect.capabilities.isEmpty)
        XCTAssertThrowsError(try connect.showLights([0])) { XCTAssertEqual($0 as? ConnectError, .notConnected) }
        XCTAssertThrowsError(try connect.refresh()) { XCTAssertEqual($0 as? ConnectError, .notConnected) }
        XCTAssertThrowsError(try connect.connect(UUID())) { XCTAssertEqual($0 as? ConnectError, .deviceNotFound) }
        connect.disconnect()
        XCTAssertEqual(connect.state, .disconnected)
    }
    func testAdditionalDriverNeedsOnlyRegistryEntry() throws {
        let registry = DriverRegistry(registrations: [
            DriverRegistration(matches: { $0 == "Future board" }, make: { FakeDriver() })
        ])
        var driver = try XCTUnwrap(registry.makeDriver(for: "Future board"))
        XCTAssertNil(registry.makeDriver(for: "Unknown"))
        XCTAssertFalse(driver.capabilities.contains(.controlLights))
        XCTAssertThrowsError(try driver.lightsCommand([0]))
        let events = try driver.receive(Data([42]), characteristic: "test-notify")
        guard case .position(let position) = events.first else { return XCTFail("Missing normalized position") }
        XCTAssertEqual(position, .initial)
    }
    func testStandardRegistryIncludesChessUpButExcludesMove() {
        XCTAssertNotNil(DriverRegistry.standard.makeDriver(for: "Chessnut Go"))
        XCTAssertNotNil(DriverRegistry.standard.makeDriver(for: "ChessUp"))
        XCTAssertNil(DriverRegistry.standard.makeDriver(for: "Chessnut Move"))
        XCTAssertNil(DriverRegistry.standard.makeDriver(for: "Chessnut Evo"))
    }
    @MainActor
    func testPositionSupportsMultipleSubscribers() {
        let connect = BoardConnect()
        var first = 0, second = 0
        let a = connect.$position.sink { _ in first += 1 }
        let b = connect.$position.sink { _ in second += 1 }
        connect.disconnect()
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 2)
        withExtendedLifetime((a, b)) {}
    }
}
private struct FakeDriver: BoardDriver {
    let capabilities: BoardCapabilities = [.readPosition]
    let profile = BluetoothProfile(services: ["test": ["test-notify"]], notificationIDs: ["test-notify"], writeID: "test-write")
    let initialCommands: [Data] = []
    func refreshCommand() throws -> Data { Data([1]) }
    func lightsCommand(_ squares: [Int]) throws -> Data { throw ConnectError.unsupportedCapability }
    mutating func receive(_ data: Data, characteristic: String) throws -> [DriverEvent] { [.position(.initial)] }
}

extension ConnectTests {
    func testMoveCoordinatesAreValidated() throws {
        let move = try BoardMove(from: BoardPosition.index("e2")!, to: BoardPosition.index("e4")!)
        XCTAssertEqual(move.from, 52)
        XCTAssertEqual(move.to, 36)
        XCTAssertThrowsError(try BoardMove(from: -1, to: 64))
        XCTAssertThrowsError(try BoardMove(from: 0, to: 0))
        XCTAssertThrowsError(try BoardMove(from: 8, to: 0, promotion: "k"))
    }
    @MainActor
    func testGenericCommandsRequireConnection() throws {
        let connect = BoardConnect()
        let move = try BoardMove(from: 52, to: 36)
        for command in [BoardCommand.requestPosition, .setLights([52,36]), .sendMove(move), .loadPosition(BoardPosition.initial.fen)] {
            XCTAssertThrowsError(try connect.send(command)) { XCTAssertEqual($0 as? ConnectError, .notConnected) }
        }
    }
}
