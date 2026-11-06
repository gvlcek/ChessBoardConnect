import Foundation
import XCTest
@testable import ChessBoardConnect

final class DriverCommandTests: XCTestCase {
    func testReadAndLightCommandsUseTransactionalStatefulPreparation() throws {
        let original = StatefulCommandDriver()
        let prepared = try DriverCommands.prepare(.requestPosition, driver: original, maximumLength: 20)
        XCTAssertEqual(prepared.packets, [Data([0x10]), Data([0x11])])
        XCTAssertTrue(prepared.driver.commandPending)
        XCTAssertFalse(original.commandPending)
        let lights = try DriverCommands.prepare(.setLights([0, 63]), driver: original, maximumLength: 20)
        XCTAssertEqual(lights.packets, [Data([0x20]), Data([0, 63])])
        XCTAssertTrue(lights.driver.commandPending)
        XCTAssertFalse(original.commandPending)
    }
    func testOversizedReadOrLightBatchCannotCommitPartialDriverState() {
        let original = StatefulCommandDriver()
        for command in [BoardCommand.requestPosition, .setLights([0, 63])] {
            XCTAssertThrowsError(try DriverCommands.prepare(command, driver: original, maximumLength: 0)) {
                XCTAssertEqual($0 as? ConnectError, .commandTooLarge)
            }
            XCTAssertFalse(original.commandPending)
        }
    }
}

/// A future driver's handshake may apply to reads/lights, not only moves and FEN.
private struct StatefulCommandDriver: BoardDriver {
    var commandPending = false
    let capabilities: BoardCapabilities = [.readPosition, .controlLights]
    let profile = BluetoothProfile(services: [:], notificationIDs: [], writeID: "test")
    let initialCommands: [Data] = []
    mutating func prepare(_ command: BoardCommand) throws -> [Data] {
        guard !commandPending else { throw ConnectError.busy }
        switch command {
        case .requestPosition:
            commandPending = true
            return [Data([0x10]), Data([0x11])]
        case .setLights(let squares):
            commandPending = true
            return [Data([0x20]), Data(squares.map(UInt8.init))]
        default: throw ConnectError.unsupportedCapability
        }
    }
    func refreshCommand() throws -> Data { throw ConnectError.unsupportedCapability }
    func lightsCommand(_ squares: [Int]) throws -> Data { throw ConnectError.unsupportedCapability }
    mutating func receive(_ data: Data, characteristic: String) throws -> [DriverEvent] { [] }
}
