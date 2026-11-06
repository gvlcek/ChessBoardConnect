import Foundation
import Combine
import ChessBoardConnect

/// Example-only dependency boundary. It does not add requirements to the public library API.
@MainActor
protocol LabBoardClient: AnyObject {
    var events: AnyPublisher<LabBoardEvent, Never> { get }
    func scan()
    func findConnectedBoards(namePrefix: String?)
    func stopScan()
    func connect(_ id: UUID) throws
    func disconnect()
    func reconnect() throws
    func send(_ command: BoardCommand) throws
    func clearLogs()
}

enum LabBoardEvent {
    case devices([BoardDevice])
    case state(ConnectionState)
    case status(String)
    case position(BoardPosition?)
    case move(BoardMove?)
    case capabilities(BoardCapabilities)
    case ready(Bool)
    case scanning(Bool)
    case canReconnect(Bool)
    case logs([String])
}

struct LabBoardState {
    var devices: [BoardDevice] = []
    var connection: ConnectionState = .idle
    var status = "Bluetooth not started"
    var position: BoardPosition?
    var lastMove: BoardMove?
    var capabilities: BoardCapabilities = []
    var ready = false
    var scanning = false
    var canReconnect = false
    var logs: [String] = []

    var connectedOrConnecting: Bool {
        switch connection {
        case .connecting, .discoveringServices, .connected, .receivingPosition: true
        default: false
        }
    }
}

/// Only this adapter knows about the concrete facade. Published values are forwarded
/// directly, avoiding reads of stale properties during @Published's willSet callbacks.
@MainActor
final class LiveLabBoardClient: LabBoardClient {
    private let connect: BoardConnect

    init(connect: BoardConnect = BoardConnect()) { self.connect = connect }

    var events: AnyPublisher<LabBoardEvent, Never> {
        Publishers.MergeMany([
            connect.$devices.map(LabBoardEvent.devices).eraseToAnyPublisher(),
            connect.$state.map(LabBoardEvent.state).eraseToAnyPublisher(),
            connect.$status.map(LabBoardEvent.status).eraseToAnyPublisher(),
            connect.$position.map(LabBoardEvent.position).eraseToAnyPublisher(),
            connect.$lastMove.map(LabBoardEvent.move).eraseToAnyPublisher(),
            connect.$capabilities.map(LabBoardEvent.capabilities).eraseToAnyPublisher(),
            connect.$ready.map(LabBoardEvent.ready).eraseToAnyPublisher(),
            connect.$scanning.map(LabBoardEvent.scanning).eraseToAnyPublisher(),
            connect.$canReconnect.map(LabBoardEvent.canReconnect).eraseToAnyPublisher(),
            connect.$logs.map(LabBoardEvent.logs).eraseToAnyPublisher()
        ]).eraseToAnyPublisher()
    }

    func scan() { connect.scan() }
    func findConnectedBoards(namePrefix: String?) { connect.findConnectedBoards(namePrefix: namePrefix) }
    func stopScan() { connect.stopScan() }
    func connect(_ id: UUID) throws { try connect.connect(id) }
    func disconnect() { connect.disconnect() }
    func reconnect() throws { try connect.reconnect() }
    func send(_ command: BoardCommand) throws { try connect.send(command) }
    func clearLogs() { connect.clearLogs() }
}
