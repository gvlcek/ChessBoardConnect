import Foundation
import Combine

public struct BoardCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let readPosition = Self(rawValue: 1 << 0)
    public static let controlLights = Self(rawValue: 1 << 1)
    public static let sendMove = Self(rawValue: 1 << 2)
    public static let loadPosition = Self(rawValue: 1 << 3)
}

public struct BoardDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let capabilities: BoardCapabilities
    public init(id: UUID, name: String, rssi: Int, capabilities: BoardCapabilities) {
        self.id = id; self.name = name; self.rssi = rssi; self.capabilities = capabilities
    }
}

public enum ConnectionState: Equatable, Sendable {
    case idle, scanning, discovered, connecting, discoveringServices, connected, receivingPosition, disconnected
    case failed(String)
}

public enum ConnectError: Error, Equatable, Sendable {
    case notConnected, deviceNotFound, busy, unsupportedCapability, invalidSquare
}

/// Main-actor API: all discovery, transport and manufacturer details stay inside Connect.
/// Published properties allow multiple subscribers; there is no single-consumer data callback.
@MainActor
public protocol BoardConnecting: ObservableObject {
    var devices: [BoardDevice] { get }
    var state: ConnectionState { get }
    var position: BoardPosition? { get }
    var lastMove: BoardMove? { get }
    var capabilities: BoardCapabilities { get }
    var ready: Bool { get }
    func send(_ command: BoardCommand) throws
    func scan()
    func stopScan()
    func connect(_ id: UUID) throws
    func disconnect()
    func refresh() throws
    /// Queue a light pattern. Successful return means queued, not physically executed.
    func showLights(_ squares: [Int]) throws
}

/// Normalized coordinates use a8=0 ... h8=7, a1=56 ... h1=63.
public struct BoardMove: Equatable, Sendable {
    public let from: Int
    public let to: Int
    public let promotion: Character?
    public init(from: Int, to: Int, promotion: Character? = nil) throws {
        guard (0..<64).contains(from), (0..<64).contains(to), from != to,
              promotion.map({ "qrbn".contains($0) }) ?? true else { throw ConnectError.invalidSquare }
        self.from = from; self.to = to; self.promotion = promotion
    }
}

public enum BoardCommand: Sendable {
    case requestPosition
    case setLights([Int])
    case sendMove(BoardMove)
    /// Full FEN, including turn and castling rights. Board support is required.
    case loadPosition(String)
}
