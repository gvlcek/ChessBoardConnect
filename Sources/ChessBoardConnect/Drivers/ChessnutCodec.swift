import Foundation

/// Classic Chessnut protocol. Based on manufacturer documentation; see README.
enum ChessnutCodec {
    static let realtime = Data([0x21, 0x01, 0x00])
    static func decode(_ frame: Data) throws -> BoardPosition {
        let bytes = Array(frame)
        guard bytes.count >= 34, bytes[0] == 0x01, Int(bytes[1]) >= 32,
              bytes.count == Int(bytes[1]) + 2 else { throw BoardError.invalidPacket }
        let pieces = Array(".qkbpnRPrBNQK")
        var squares = Array(repeating: Character("."), count: 64)
        for row in 0..<8 {
            for file in 0..<8 {
                let column = 7 - file
                let byte = bytes[2 + (row * 8 + column) / 2]
                let code = Int(column.isMultiple(of: 2) ? byte & 15 : byte >> 4)
                guard code < pieces.count else { throw BoardError.invalidPacket }
                squares[row * 8 + file] = pieces[code]
            }
        }
        return try BoardPosition(squares: squares)
    }
    static func leds(_ squares: [Int]) -> Data {
        var bytes: [UInt8] = [0x0a, 0x08] + Array(repeating: 0, count: 8)
        for index in squares where (0..<64).contains(index) {
            bytes[2 + index / 8] |= UInt8(1 << (7 - index % 8))
        }
        return Data(bytes)
    }
}

/// Handles fragmented or coalesced notifications using the protocol's length byte.
struct ChessnutFrames {
    private var buffer = Data()
    mutating func append(_ bytes: Data) -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 2 {
            let header = Array(buffer.prefix(2))
            guard header[0] == 1, (32...64).contains(Int(header[1])) else {
                buffer.removeFirst(); continue
            }
            let length = Int(header[1]) + 2
            guard buffer.count >= length else { break }
            frames.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length)
        }
        return frames
    }
}
