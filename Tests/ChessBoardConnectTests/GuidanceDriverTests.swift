import Foundation
import Combine
import XCTest
@testable import ChessBoardConnect

/// Real manufacturer fixtures through the guidance coordinator; transport writes
/// are captured in memory. These are not Core Bluetooth adapter integration tests.
final class GuidanceDriverTests: XCTestCase {
    private let fen = BoardPosition.initial.fen + " w KQkq - 0 1"

    @MainActor
    func testChessUpFENHandshakeAndMoveAcceptanceDoNotCompletePhysicalGuidance() throws {
        let client = DriverGuidanceHarness()
        let guide = BoardGuidance(connection: client, settle: {})
        try guide.prepareSession(fen: fen)
        XCTAssertEqual(client.writes.first, Data([0x64]))
        try client.receive([0xB1])
        XCTAssertEqual(client.writes.last, Data([0xB9,5,0,1,1,0,1,1,0,0,0,0]))
        XCTAssertEqual(guide.state, .preparing)
        try client.receive([0x24])
        XCTAssertEqual(guide.state, .ready)
        let target = try BoardPosition(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR")
        try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: target)
        XCTAssertEqual(client.writes.last, Data([0x99, 12, 28]))
        try client.receive([0x22])
        guard case .awaitingMove = guide.state else { return XCTFail("ACK was mistaken for physical completion") }
        try client.receive([0xA3,0x35,4,1,4,3])
        guard case .completed(let completion) = guide.state else { return XCTFail("Physical report did not complete") }
        XCTAssertEqual(completion.evidence, .reportedMove)
        XCTAssertEqual(client.writes.last, Data([0x21]))
    }

    @MainActor
    func testChessUpPromotionRequiresBothProtocolAndReportedPieceConfirmation() throws {
        let client = DriverGuidanceHarness()
        let guide = BoardGuidance(connection: client, settle: {})
        try guide.prepareSession(fen: "7k/P7/8/8/8/8/8/7K w - - 0 1")
        try client.receive([0xB1]); try client.receive([0x24])
        let target = try BoardPosition(fen: "N6k/8/8/8/8/8/8/7K")
        try guide.guideMove(BoardMove(from: 8, to: 0, promotion: "n"), expectedPosition: target)
        try client.receive([0x22])
        XCTAssertEqual(client.writes.last, Data([0x97,2]))
        try client.receive([0xA3,0x35,0,6,0,7])
        try client.receive([0x23])
        guard case .awaitingMove = guide.state else { return XCTFail("The physical promotion piece is still unknown") }
        try client.receive([0x97,2])
        guard case .completed(let completion) = guide.state else { return XCTFail("Promotion not completed") }
        XCTAssertEqual(completion.request.move.promotion, "n")
        XCTAssertEqual(client.writes.last, Data([0x23]))
    }
}

@MainActor
private final class DriverGuidanceHarness: GuidanceConnection {
    var ready = true
    var capabilities: BoardCapabilities { driver.capabilities }
    var owner: UUID?
    var writes: [Data] = []
    private var driver = ChessUpDriver()
    private var commandID: UUID?
    private let subject = PassthroughSubject<BoardEvent, Never>()
    var events: AnyPublisher<BoardEvent, Never> { subject.eraseToAnyPublisher() }
    func acquireGuidance(owner: UUID) throws { self.owner = owner }
    func sendGuidance(_ command: BoardCommand, id: UUID, owner: UUID) throws {
        let packets = try driver.prepare(command)
        if driver.commandPending { commandID = id }
        writes += packets
    }
    func receive(_ bytes: [UInt8]) throws {
        let events = try driver.receive(Data(bytes), characteristic: ChessUpDriver.notify)
        let confirmedID = driver.commandPending ? nil : commandID
        if confirmedID != nil { commandID = nil }
        for event in events {
            switch event {
            case .write(let bytes): writes.append(bytes)
            case .commandConfirmed:
                if let confirmedID { subject.send(.commandConfirmed(confirmedID)) }
            case .move(let move): subject.send(.move(move))
            default: break
            }
        }
    }
    func endGuidance(owner: UUID) { if self.owner == owner { self.owner = nil } }
}
