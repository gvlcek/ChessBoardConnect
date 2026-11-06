import Foundation
import Combine

/// Reusable entry point. No Core Bluetooth types or manufacturer packets escape this boundary.
@MainActor
public final class BoardConnect: BoardConnecting {
    @Published public private(set) var devices: [BoardDevice] = []
    @Published public private(set) var state: ConnectionState = .idle
    @Published public private(set) var status = "Bluetooth not started"
    @Published public private(set) var position: BoardPosition?
    @Published public private(set) var lastMove: BoardMove?
    @Published public private(set) var capabilities: BoardCapabilities = []
    @Published public private(set) var ready = false
    @Published public private(set) var scanning = false
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var canReconnect = false
    public var connectedOrConnecting: Bool { session.connectedOrConnecting }
    @Published public private(set) var guidanceActive = false
    public var events: AnyPublisher<BoardEvent, Never> { session.events }
    private var guidanceOwner: UUID?
    private let session: BluetoothSession
    private var subscriptions = Set<AnyCancellable>()

    public init() {
        session = BluetoothSession()
        session.$devices.sink { [weak self] in self?.devices = $0 }.store(in: &subscriptions)
        session.$state.sink { [weak self] in self?.state = $0 }.store(in: &subscriptions)
        session.$status.sink { [weak self] in self?.status = $0 }.store(in: &subscriptions)
        session.$lastMove.sink { [weak self] in self?.lastMove = $0 }.store(in: &subscriptions)
        session.$position.sink { [weak self] in self?.position = $0 }.store(in: &subscriptions)
        session.$capabilities.sink { [weak self] in self?.capabilities = $0 }.store(in: &subscriptions)
        session.$ready.sink { [weak self] in self?.ready = $0 }.store(in: &subscriptions)
        session.$canReconnect.sink { [weak self] in self?.canReconnect = $0 }.store(in: &subscriptions)
        session.$scanning.sink { [weak self] in self?.scanning = $0 }.store(in: &subscriptions)
        session.$logs.sink { [weak self] in self?.logs = $0 }.store(in: &subscriptions)
    }
    public func send(_ command: BoardCommand) throws { _ = try submit(command) }
    /// Queue a command and return its correlation ID. Only protocols with explicit
    /// confirmations emit commandConfirmed; this is not a physical-move result.
    @discardableResult
    public func submit(_ command: BoardCommand) throws -> UUID {
        guard guidanceOwner == nil else { throw ConnectError.busy }
        let id = UUID()
        try session.send(command, id: id)
        return id
    }
    public func scan() { session.scan() }
    /// Finds supported boards already connected to iOS, including by another app.
    public func findConnectedBoards(namePrefix: String? = nil) { session.findConnectedBoards(namePrefix: namePrefix) }
    public func stopScan() { session.stopScan() }
    public func connect(_ id: UUID) throws { try session.connect(id) }
    public func disconnect() { session.disconnect() }
    /// Clears recorded events without changing the connection or current readings.
    public func clearLogs() { session.clearLogs() }
    public func reconnect() throws { try session.reconnect() }
    public func refresh() throws { try send(.requestPosition) }
    public func showLights(_ squares: [Int]) throws { try send(.setLights(squares)) }
}

// A guidance session owns command submission, while discovery, observations,
// diagnostics and explicit disconnect remain available to the host app.
extension BoardConnect: GuidanceConnection {
    func acquireGuidance(owner: UUID) throws {
        guard ready else { throw ConnectError.notConnected }
        guard guidanceOwner == nil || guidanceOwner == owner else { throw ConnectError.busy }
        guidanceOwner = owner
        guidanceActive = true
    }
    func sendGuidance(_ command: BoardCommand, id: UUID, owner: UUID) throws {
        guard guidanceOwner == owner else { throw ConnectError.busy }
        try session.send(command, id: id)
    }
    func endGuidance(owner: UUID) {
        guard guidanceOwner == owner else { return }
        // A ChessUp move cannot be withdrawn reliably. Close that connection so
        // late replies cannot be mistaken for work in a new guidance session.
        let canClearLights = capabilities.contains([.readPosition, .controlLights])
            && !session.hasPendingProtocolCommand
        if ready, canClearLights { try? session.showLights([]) }
        if ready, !canClearLights { session.disconnect() }
        guidanceOwner = nil
        guidanceActive = false
    }
}
