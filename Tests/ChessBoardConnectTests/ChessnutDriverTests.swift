import Foundation
import XCTest
@testable import ChessBoardConnect

final class ChessnutDriverTests: XCTestCase {
    private var validFrame: Data {
        let payload: [UInt8] = [0x58, 0x23, 0x31, 0x85]
            + Array(repeating: 0x44, count: 4)
            + Array(repeating: 0, count: 16)
            + Array(repeating: 0x77, count: 4)
            + [0xA6, 0xC9, 0x9B, 0x6A]
        return Data([1, 32] + payload)
    }
    private var corruptFrame: Data {
        var frame = validFrame
        frame[2] = 0xFF
        return frame
    }
    func testCorruptFrameDoesNotDiscardLaterValidFrameInSameNotification() throws {
        var driver = ChessnutDriver()
        let events = try driver.receive(corruptFrame + validFrame,
                                        characteristic: driver.profile.notificationIDs.first!)
        let positions = events.compactMap { event -> BoardPosition? in
            if case .position(let value) = event { return value }
            return nil
        }
        XCTAssertEqual(positions, [.initial])
        guard case .invalidData = events.first else { return XCTFail("Missing invalidation") }
        guard case .position = events.last else { return XCTFail("Missing recovered reading") }
    }
    func testCorruptionAfterValidReadingInvalidatesItAndNextReadingRecovers() throws {
        var driver = ChessnutDriver()
        let characteristic = driver.profile.notificationIDs.first!
        let events = try driver.receive(validFrame + corruptFrame, characteristic: characteristic)
        XCTAssertEqual(events.count, 2)
        guard case .position = events.first else { return XCTFail("Missing first reading") }
        guard case .invalidData = events.last else { return XCTFail("Corrupt last frame must invalidate") }
        let recovered = try driver.receive(validFrame, characteristic: characteristic)
        guard case .position(let position) = recovered.first else { return XCTFail("Cannot recover") }
        XCTAssertEqual(position, .initial)
    }
    func testFragmentedBatchPreservesValidReadingsOnBothSidesOfCorruption() throws {
        var driver = ChessnutDriver()
        let characteristic = driver.profile.notificationIDs.first!
        let batch = validFrame + corruptFrame + validFrame
        XCTAssertTrue(try driver.receive(batch.prefix(10), characteristic: characteristic).isEmpty)
        let events = try driver.receive(batch.dropFirst(10), characteristic: characteristic)
        XCTAssertEqual(events.count, 3)
        guard case .position = events[0], case .invalidData = events[1], case .position = events[2] else {
            return XCTFail("Events must preserve wire order")
        }
    }
    func testUnrelatedCharacteristicDoesNotAlterTheFrameBuffer() throws {
        var driver = ChessnutDriver()
        XCTAssertTrue(try driver.receive(corruptFrame, characteristic: "not-the-board-data").isEmpty)
        let events = try driver.receive(validFrame, characteristic: driver.profile.notificationIDs.first!)
        XCTAssertEqual(events.count, 1)
        guard case .position(let position) = events.first else { return XCTFail("Missing reading") }
        XCTAssertEqual(position, .initial)
    }
}
