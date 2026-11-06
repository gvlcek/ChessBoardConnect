import Foundation

public struct BoardGuidanceRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let move: BoardMove
    /// Supplied by the app's chess rules/PGN layer; never treated as a sensor reading.
    public let expectedPosition: BoardPosition
    public init(id: UUID = UUID(), move: BoardMove, expectedPosition: BoardPosition) {
        self.id = id; self.move = move; self.expectedPosition = expectedPosition
    }
}

public enum BoardGuidanceEvidence: Equatable, Sendable {
    case sensorPosition
    /// A reported move does not prove the placement of all 64 squares.
    case reportedMove
}

public struct BoardGuidanceCompletion: Equatable, Sendable {
    public let request: BoardGuidanceRequest
    public let evidence: BoardGuidanceEvidence
}

public enum BoardGuidanceError: Error, Equatable, Sendable, LocalizedError {
    case notConnected, unsupportedBoard, busy, sessionNotPrepared, invalidPosition, inconsistentTarget
    case connectionLost, commandFailed(String), unexpectedMove(BoardMove)
    public var errorDescription: String? {
        switch self {
        case .notConnected: "Connect to a board before starting guidance."
        case .unsupportedBoard: "This board does not provide a supported guidance strategy."
        case .busy: "Finish or cancel the current guidance operation first."
        case .sessionNotPrepared: "Prepare a guidance session before guiding a move."
        case .invalidPosition: "Enter a valid initial FEN position."
        case .inconsistentTarget: "The expected position must leave the origin empty and place a piece on the destination, matching the promotion choice when provided."
        case .connectionLost: "The connection was lost. Reconnect and prepare a new guidance session."
        case .commandFailed(let message): "Guidance command failed: \(message)"
        case .unexpectedMove: "The board reported a different move. Prepare the session again before continuing."
        }
    }
}

public enum BoardGuidanceState: Equatable, Sendable {
    case idle
    case preparing
    /// Session preparation is complete. This is not a claim that every board
    /// verified its physical starting position (see the selected board's capabilities).
    case ready
    case awaitingMove(BoardGuidanceRequest)
    case completed(BoardGuidanceCompletion)
    case cancelled
    case failed(BoardGuidanceError)

    public var canGuideMove: Bool {
        switch self { case .ready, .completed: true; default: false }
    }
    public var isActive: Bool {
        switch self { case .preparing, .ready, .awaitingMove, .completed: true; default: false }
    }
}
