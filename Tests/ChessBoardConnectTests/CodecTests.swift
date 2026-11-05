import Foundation
import XCTest
@testable import ChessBoardConnect

final class CoreChecks: XCTestCase {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        XCTAssertTrue(condition(), message)
    }
    func testWireProtocol() throws {
        expect(BoardPosition.initial.fen == "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR", "Initial FEN")
        for i in 0..<64 { expect(BoardPosition.index(BoardPosition.name(i)) == i, "Square orientation \(i)") }
        // Independently specified wire bytes: h8 rook=8 (low), g8 knight=5 (high).
        let initialPayload: [UInt8] = [0x58,0x23,0x31,0x85] + Array(repeating: 0x44, count: 4) + Array(repeating: 0, count: 16) + Array(repeating: 0x77, count: 4) + [0xA6,0xC9,0x9B,0x6A]
        let packet = Data([0x01,0x20] + initialPayload)
        let decoded = try ChessnutCodec.decode(packet)
        expect(decoded == .initial, "Piece mapping/orientation")
        let extended = try ChessnutCodec.decode(Data([1,34] + initialPayload + [0,0]))
        expect(extended == .initial, "36-byte report")
        var bad = packet; bad[2] = 0xF8
        do { _ = try ChessnutCodec.decode(bad); fatalError("Accepted unknown piece") } catch BoardError.invalidPacket {}
        do { _ = try ChessnutCodec.decode(packet.dropLast()); fatalError("Accepted truncated frame") } catch BoardError.invalidPacket {}
        var frames = ChessnutFrames()
        expect(frames.append(packet.prefix(10)).isEmpty, "Partial frame emitted")
        let reconstructed = frames.append(Data(packet.dropFirst(10)) + packet)
        expect(reconstructed == [packet,packet], "Fragmented/coalesced frames")
        let e2 = BoardPosition.index("e2")!, e4 = BoardPosition.index("e4")!
        expect(Array(ChessnutCodec.leds([e2,e4])) == [10,8,0,0,0,0,8,0,8,0], "LED file/rank mapping")
        expect(Array(ChessnutCodec.leds([0,63])) == [10,8,128,0,0,0,0,0,0,1], "LED corners")
        expect(Array(ChessnutCodec.leds([])) == [10,8,0,0,0,0,0,0,0,0], "Lights off")
        do { _ = try BoardPosition(fen: "9/8/8/8/8/8/8/8"); fatalError("Invalid FEN accepted") } catch BoardError.invalidPosition {}

    }
}
