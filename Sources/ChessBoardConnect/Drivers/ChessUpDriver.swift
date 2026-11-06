import Foundation

/// Experimental ChessUp UART protocol. A session starts only on explicit loadPosition.
/// Received moves are board events, not a reconstruction of the sensor position.
struct ChessUpDriver: BoardDriver {
    static let service = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    static let notify = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
    static let write = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
    let profile = BluetoothProfile(services: [service: [write, notify]], notificationIDs: [notify], writeID: write)
    let capabilities: BoardCapabilities = [.sendMove, .loadPosition, .receiveMoves]
    let initialCommands: [Data] = []
    private enum Pending {
        case position, settings, move(BoardMove), promotion
    }
    private var pending: Pending?
    private var initialized = false
    private var receivedMove: BoardMove?
    var commandPending: Bool { pending != nil }

    mutating func prepare(_ command: BoardCommand) throws -> [Data] {
        guard pending == nil else { throw ConnectError.busy }
        switch command {
        case .loadPosition(let fen):
            let packet = try Self.encodePosition(fen)
            initialized = false; receivedMove = nil; pending = .position
            return [Data([0x64]), packet]
        case .sendMove(let move):
            guard initialized else { throw ConnectError.sessionNotInitialized }
            pending = .move(move)
            return [Data([0x99, Self.wireIndex(move.from), Self.wireIndex(move.to)])]
        default: throw ConnectError.unsupportedCapability
        }
    }
    func refreshCommand() throws -> Data { throw ConnectError.unsupportedCapability }
    func lightsCommand(_ squares: [Int]) throws -> Data { throw ConnectError.unsupportedCapability }

    mutating func receive(_ data: Data, characteristic: String) throws -> [DriverEvent] {
        guard characteristic.lowercased() == Self.notify, let opcode = data.first else { return [] }
        let bytes = Array(data)
        switch opcode {
        case 0xb1:
            guard case .position = pending else { return [] }
            pending = .settings
            // Study/analysis mode: both colors controlled by the human, no assistance.
            return [.status("ChessUp accepted FEN; configuring study mode…"),
                    .write(Data([0xb9, 5, 0, 1, 1, 0, 1, 1, 0, 0, 0, 0]))]
        case 0x24:
            guard case .settings = pending else { return [] }
            pending = nil; initialized = true
            return [.status("ChessUp study session confirmed. Ready for moves."), .commandConfirmed]
        case 0x22:
            return confirmMove()
        case 0x26:
            // Duplicate-move response: the board already accepted this exact move.
            if case .move(let move) = pending, bytes.count >= 7, bytes[1] == 0x99,
               bytes[2] == 0, bytes[3] == 1, bytes[5] == Self.wireIndex(move.from), bytes[6] == Self.wireIndex(move.to) {
                return confirmMove()
            }
            throw BoardError.invalidPacket
        case 0x23:
            guard case .promotion = pending else { return [] }
            pending = nil
            return [.status("ChessUp confirmed promotion."), .commandConfirmed]
        case 0xa3:
            guard bytes.count >= 6, bytes[1] == 0x35,
                  bytes[2...5].allSatisfy({ $0 < 8 }) else { throw BoardError.invalidPacket }
            let move = try BoardMove(from: (7 - Int(bytes[3])) * 8 + Int(bytes[2]),
                                     to: (7 - Int(bytes[5])) * 8 + Int(bytes[4]))
            receivedMove = move
            return [.write(Data([0x21])), .move(move)]
        case 0x97:
            guard bytes.count >= 2, let previous = receivedMove,
                  previous.to / 8 == 0 || previous.to / 8 == 7,
                  let piece = Self.promotionPiece(bytes[1]) else { throw BoardError.invalidPacket }
            let promoted = try BoardMove(from: previous.from, to: previous.to, promotion: piece)
            receivedMove = nil
            return [.write(Data([0x23])), .move(promoted)]
        default:
            // Touches and unknown packets remain visible in the raw RX log.
            return []
        }
    }
    private mutating func confirmMove() -> [DriverEvent] {
        guard case .move(let move) = pending else { return [] }
        if let promotion = move.promotion {
            pending = .promotion
            return [.write(Data([0x97, Self.promotionCode(promotion)])), .status("ChessUp confirmed move; sending promotion…")]
        }
        pending = nil
        return [.status("ChessUp confirmed move \(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))."), .commandConfirmed]
    }
    static func wireIndex(_ square: Int) -> UInt8 { UInt8((7 - square / 8) * 8 + square % 8) }
    private static func promotionCode(_ piece: Character) -> UInt8 {
        switch piece { case "r": 1; case "n": 2; case "b": 3; default: 4 }
    }
    private static func promotionPiece(_ code: UInt8) -> Character? {
        switch code { case 1: "r"; case 2: "n"; case 3: "b"; case 4: "q"; default: nil }
    }
    static func encodePosition(_ fen: String) throws -> Data {
        let fields = fen.split(separator: " ").map(String.init)
        guard fen.utf8.allSatisfy({ $0 < 128 }), fields.count == 6, fields[1] == "w" || fields[1] == "b",
              fields[2] == "-" || (!fields[2].isEmpty && Set(fields[2]).count == fields[2].count && fields[2].allSatisfy({ "KQkq".contains($0) })),
              fields[3] == "-" || (BoardPosition.index(fields[3]) != nil && (fields[3].last == "3" || fields[3].last == "6")),
              fields[4].allSatisfy({ $0.isASCII && $0.isNumber }), let halfmove = UInt8(fields[4]),
              fields[5].allSatisfy({ $0.isASCII && $0.isNumber }), let fullmove = UInt16(fields[5]), fullmove > 0 else { throw ConnectError.invalidFEN }
        do { _ = try BoardPosition(fen: fields[0]) } catch { throw ConnectError.invalidFEN }
        let text = fields.prefix(4).joined(separator: " ") + " "
        var payload = Array(text.utf8)
        payload += [halfmove, UInt8(fullmove >> 8), UInt8(fullmove & 255)]
        guard payload.count <= 255 else { throw ConnectError.invalidFEN }
        return Data([0x66, UInt8(payload.count)] + payload)
    }
}
