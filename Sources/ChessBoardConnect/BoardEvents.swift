import Foundation

/// Live events, not a replay of cached readings. Published on MainActor.
public enum BoardEvent: Equatable, Sendable {
    case connectionState(ConnectionState)
    case position(BoardPosition?)
    case move(BoardMove)
    /// Manufacturer-protocol confirmation; never a claim of physical execution.
    case commandConfirmed(UUID)
}
