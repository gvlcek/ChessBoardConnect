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
    public var canReconnect: Bool { session.canReconnect }
    public var connectedOrConnecting: Bool { session.connectedOrConnecting }
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
        session.$scanning.sink { [weak self] in self?.scanning = $0 }.store(in: &subscriptions)
        session.$logs.sink { [weak self] in self?.logs = $0 }.store(in: &subscriptions)
    }
    public func send(_ command: BoardCommand) throws { try session.send(command) }
    public func scan() { session.scan() }
    public func stopScan() { session.stopScan() }
    public func connect(_ id: UUID) throws { try session.connect(id) }
    public func disconnect() { session.disconnect() }
    /// Clears recorded events without changing the connection or current readings.
    public func clearLogs() { session.clearLogs() }
    public func reconnect() throws { try session.reconnect() }
    public func refresh() throws { try session.refresh() }
    public func showLights(_ squares: [Int]) throws { try session.showLights(squares) }
}
