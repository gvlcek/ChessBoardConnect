import Foundation

/// Piece placement only: a8...h8, then a7...h7, down to a1...h1.
/// Turn, castling rights and en-passant belong to the game, not the sensors.
public struct BoardPosition: Equatable, Sendable {
    public let squares: [Character]
    public static let initial = try! BoardPosition(fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR")

    public init(fen: String) throws {
        let ranks = (fen.split(separator: " ").first ?? "").split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else { throw BoardError.invalidPosition }
        var result: [Character] = []
        for rank in ranks {
            var row: [Character] = []
            for c in rank {
                if let n = c.wholeNumberValue, c.isASCII, (1...8).contains(n) {
                    guard row.count + n <= 8 else { throw BoardError.invalidPosition }
                    row += Array(repeating: ".", count: n)
                }
                else if "prnbqkPRNBQK".contains(c), row.count < 8 { row.append(c) }
                else { throw BoardError.invalidPosition }
            }
            guard row.count == 8 else { throw BoardError.invalidPosition }
            result += row
        }
        squares = result
    }
    public init(squares: [Character]) throws {
        guard squares.count == 64, squares.allSatisfy({ ".prnbqkPRNBQK".contains($0) }) else { throw BoardError.invalidPosition }
        self.squares = squares
    }
    public static func index(_ name: String) -> Int? {
        let chars = Array(name)
        guard chars.count == 2, chars[1].isASCII, let file = "abcdefgh".firstIndex(of: chars[0]), let rank = chars[1].wholeNumberValue, (1...8).contains(rank) else { return nil }
        return (8 - rank) * 8 + "abcdefgh".distance(from: "abcdefgh".startIndex, to: file)
    }
    /// Algebraic name for a normalized square. The index must be in `0..<64`.
    public static func name(_ index: Int) -> String { "\(Array("abcdefgh")[index % 8])\(8 - index / 8)" }
    public var fen: String {
        (0..<8).map { row in
            var text = "", empty = 0
            for c in squares[(row * 8)..<(row * 8 + 8)] {
                if c == "." { empty += 1 }
                else { if empty > 0 { text += String(empty); empty = 0 }; text.append(c) }
            }
            if empty > 0 { text += String(empty) }
            return text
        }.joined(separator: "/")
    }
    public func differences(from other: BoardPosition) -> [Int] { (0..<64).filter { squares[$0] != other.squares[$0] } }
}
public enum BoardError: Error { case invalidPosition, invalidPacket }
