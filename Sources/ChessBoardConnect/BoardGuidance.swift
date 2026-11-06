import Foundation
import Combine

@MainActor
protocol GuidanceConnection: AnyObject, Sendable {
    var ready: Bool { get }
    var capabilities: BoardCapabilities { get }
    var events: AnyPublisher<BoardEvent, Never> { get }
    func acquireGuidance(owner: UUID) throws
    func sendGuidance(_ command: BoardCommand, id: UUID, owner: UUID) throws
    func endGuidance(owner: UUID)
}

/// Guides one app-supplied move at a time. Does not parse PGN, apply chess rules,
/// advance a game, or reconstruct sensor positions from ChessUp events.
@MainActor
public final class BoardGuidance: ObservableObject {
    public private(set) var state: BoardGuidanceState = .idle
    private let stateSubject = CurrentValueSubject<BoardGuidanceState, Never>(.idle)
    /// State is stored before emission, so a completion subscriber can immediately
    /// submit the next move without reentering an @Published willSet callback.
    public var states: AnyPublisher<BoardGuidanceState, Never> { stateSubject.eraseToAnyPublisher() }
    @Published public private(set) var differingSquares: [Int] = []
    public var isSupported: Bool { Strategy.select(connection.capabilities) != nil }

    private enum Strategy {
        case positions, moves
        static func select(_ capabilities: BoardCapabilities) -> Self? {
            if capabilities.contains([.readPosition, .controlLights]) { return .positions }
            if capabilities.contains([.sendMove, .receiveMoves, .loadPosition]) { return .moves }
            return nil
        }
    }
    private struct Operation {
        let id: UUID
        let strategy: Strategy
        let target: BoardPosition
        var request: BoardGuidanceRequest?
        var commandAccepted = false
        var moveReported = false
    }
    private let connection: any GuidanceConnection
    private let owner = UUID()
    private let settle: @Sendable () async throws -> Void
    private var strategy: Strategy?
    private var operation: Operation?
    private var sessionPrepared = false
    private var transitioning = false
    private var emittingState = false
    private var pendingStates: [BoardGuidanceState] = []
    private var ownsConnection = false
    private var latestPosition: BoardPosition?
    private var lastLightPattern: [Int]?
    private var subscription: AnyCancellable?
    private var settleTask: Task<Void, Never>?
    private var settlingID: UUID?

    /// Exact sensor matches must remain stable for this interval. Identical
    /// repeated reports do not restart it. Human actions have no automatic timeout;
    /// manufacturer command timeouts remain enforced by the connection layer.
    public convenience init(connect: BoardConnect, settleDuration: Duration = .milliseconds(250)) {
        let delay = max(.zero, settleDuration)
        self.init(connection: connect, settle: { try await Task.sleep(for: delay) })
    }
    init(connection: any GuidanceConnection,
         settle: @escaping @Sendable () async throws -> Void = { try await Task.sleep(for: .milliseconds(250)) }) {
        self.connection = connection
        self.settle = settle
        subscription = connection.events.sink { [weak self] in self?.receive($0) }
    }
    deinit {
        settleTask?.cancel()
        let connection = connection
        let owner = owner
        Task { @MainActor in connection.endGuidance(owner: owner) }
    }

    /// On position-reading boards, waits for a fresh exact starting-position match.
    /// On move-reporting boards, loads FEN and waits for protocol confirmation.
    /// This does not verify a sensor layout on boards that do not expose one.
    public func prepareSession(fen: String) throws {
        guard !transitioning, operation == nil else { throw BoardGuidanceError.busy }
        guard connection.ready else { throw BoardGuidanceError.notConnected }
        guard let selected = Strategy.select(connection.capabilities) else { throw BoardGuidanceError.unsupportedBoard }
        let target: BoardPosition
        do { target = try BoardPosition(fen: fen) }
        catch { throw BoardGuidanceError.invalidPosition }
        try connection.acquireGuidance(owner: owner)
        ownsConnection = true
        sessionPrepared = false
        strategy = selected
        latestPosition = nil
        lastLightPattern = nil
        let op = Operation(id: UUID(), strategy: selected, target: target)
        operation = op
        differingSquares = []
        guard operation?.id == op.id else { return }
        publish(.preparing)
        guard operation?.id == op.id else { return }
        do {
            switch selected {
            case .positions: try send(.requestPosition, operation: op)
            case .moves: try send(.loadPosition(fen), operation: op)
            }
        } catch { failCommand(error, id: op.id); throw error }
    }

    /// expectedPosition comes from the host's chess logic. Its legality and
    /// consistency with move are the caller's responsibility.
    @discardableResult
    public func guideMove(_ move: BoardMove, expectedPosition: BoardPosition) throws -> UUID {
        guard !transitioning, operation == nil else { throw BoardGuidanceError.busy }
        guard connection.ready else { throw BoardGuidanceError.notConnected }
        guard sessionPrepared, let strategy, ownsConnection else { throw BoardGuidanceError.sessionNotPrepared }
        guard expectedPosition.squares[move.from] == ".", expectedPosition.squares[move.to] != ".",
              move.promotion.map({ expectedPosition.squares[move.to].lowercased() == String($0) }) ?? true else {
            throw BoardGuidanceError.inconsistentTarget
        }
        let request = BoardGuidanceRequest(move: move, expectedPosition: expectedPosition)
        let op = Operation(id: request.id, strategy: strategy, target: expectedPosition, request: request)
        operation = op
        latestPosition = nil
        lastLightPattern = nil
        differingSquares = []
        guard operation?.id == op.id else { return request.id }
        publish(.awaitingMove(request))
        guard operation?.id == op.id else { return request.id }
        do {
            switch strategy {
            case .positions:
                try setLights([move.from, move.to].sorted(), operation: op)
                try send(.requestPosition, operation: op)
            case .moves: try send(.sendMove(move), operation: op)
            }
        } catch { failCommand(error, id: op.id); throw error }
        return request.id
    }

    /// Revalidate an active sensor target, for example when the host returns to
    /// the foreground. Never resends a move-protocol command.
    public func refresh() {
        guard let op = operation, op.strategy == .positions, ownsConnection else { return }
        cancelSettling()
        latestPosition = nil
        do { try send(.requestPosition, operation: op) }
        catch { failCommand(error, id: op.id) }
    }

    /// Releases the session. Position/light boards queue lights off and stay connected
    /// when no protocol reply is pending. Move-protocol boards disconnect because
    /// an already-issued physical move cannot be safely withdrawn.
    public func cancel() {
        guard !transitioning, ownsConnection else { return }
        transitioning = true
        sessionPrepared = false
        ownsConnection = false
        clearOperation()
        connection.endGuidance(owner: owner)
        transitioning = false
        publish(.cancelled)
    }

    private func receive(_ event: BoardEvent) {
        if case .connectionState = event { objectWillChange.send() }
        guard ownsConnection else { return }
        if case .connectionState(let state) = event {
            switch state {
            case .disconnected, .failed: fail(.connectionLost)
            default: break
            }
            return
        }
        guard var op = operation else {
            // A move made between guided requests changes the board's game context.
            // Ignore duplicate reports of the completed move, but require a fresh
            // setup after any other unsolicited move on a move-reporting board.
            if strategy == .moves, sessionPrepared, case .move(let move) = event {
                if case .completed(let result) = state, result.request.move == move { return }
                fail(.unexpectedMove(move))
            }
            return
        }
        switch event {
        case .position(let position):
            guard op.strategy == .positions else { return }
            latestPosition = position
            guard let position else { cancelSettling(); return }
            let differences = position.differences(from: op.target)
            if differingSquares != differences { differingSquares = differences }
            guard operation?.id == op.id else { return }
            do { try setLights(differences, operation: op) }
            catch { failCommand(error, id: op.id); return }
            guard operation?.id == op.id else { return }
            if differences.isEmpty { beginSettling(op) } else { cancelSettling() }
        case .commandConfirmed(let id):
            guard op.strategy == .moves, op.id == id else { return }
            if op.request == nil { complete(op, evidence: .reportedMove); return }
            op.commandAccepted = true
            operation = op
            if op.moveReported { complete(op, evidence: .reportedMove) }
        case .move(let move):
            guard op.strategy == .moves, let request = op.request else { return }
            // Promotions arrive as a move followed by the piece choice.
            if request.move.promotion != nil, move.promotion == nil,
               request.move.from == move.from, request.move.to == move.to { return }
            guard move == request.move else { fail(.unexpectedMove(move)); return }
            op.moveReported = true
            operation = op
            if op.commandAccepted { complete(op, evidence: .reportedMove) }
        default: break
        }
    }
    private func send(_ command: BoardCommand, operation op: Operation) throws {
        guard operation?.id == op.id, ownsConnection else { return }
        try connection.sendGuidance(command, id: op.id, owner: owner)
    }
    private func setLights(_ squares: [Int], operation op: Operation) throws {
        guard lastLightPattern != squares, operation?.id == op.id else { return }
        lastLightPattern = squares
        try send(.setLights(squares), operation: op)
    }
    private func beginSettling(_ op: Operation) {
        guard settleTask == nil else { return }
        let id = UUID()
        settlingID = id
        let settle = settle
        settleTask = Task { [weak self] in
            do { try await settle() } catch { return }
            guard !Task.isCancelled, let self, self.settlingID == id,
                  self.operation?.id == op.id, self.latestPosition == op.target else { return }
            self.settleTask = nil; self.settlingID = nil
            self.complete(op, evidence: .sensorPosition)
        }
    }
    private func cancelSettling() {
        settleTask?.cancel(); settleTask = nil; settlingID = nil
    }
    private func clearOperation() {
        cancelSettling()
        operation = nil
        latestPosition = nil
        lastLightPattern = nil
        if !differingSquares.isEmpty { differingSquares = [] }
    }
    private func complete(_ op: Operation, evidence: BoardGuidanceEvidence) {
        guard operation?.id == op.id, ownsConnection else { return }
        transitioning = true
        clearOperation()
        sessionPrepared = true
        transitioning = false
        if let request = op.request {
            publish(.completed(BoardGuidanceCompletion(request: request, evidence: evidence)))
        } else { publish(.ready) }
    }
    private func publish(_ value: BoardGuidanceState) {
        state = value
        pendingStates.append(value)
        guard !emittingState else { return }
        emittingState = true
        // A subscriber may submit/cancel a request synchronously. Drain those
        // transitions after every observer has received the current transition.
        while !pendingStates.isEmpty { stateSubject.send(pendingStates.removeFirst()) }
        emittingState = false
        objectWillChange.send()
    }
    private func failCommand(_ error: Error, id: UUID) {
        guard operation?.id == id else { return }
        fail(.commandFailed(error.localizedDescription))
    }
    private func fail(_ error: BoardGuidanceError) {
        transitioning = true
        sessionPrepared = false
        ownsConnection = false
        clearOperation()
        connection.endGuidance(owner: owner)
        transitioning = false
        publish(.failed(error))
    }
}
