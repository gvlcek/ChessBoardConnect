import Foundation
import Combine
import XCTest
@testable import ChessBoardConnect

final class BoardGuidanceTests: XCTestCase {
    private let e4 = try! BoardPosition(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR")
    private let e5 = try! BoardPosition(fen: "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR")
    private let initialFEN = BoardPosition.initial.fen + " w KQkq - 0 1"

    @MainActor
    func testPreparationRejectsDisconnectedUnsupportedAndMalformedInputWithoutSending() throws {
        let client = GuidanceStub(capabilities: [])
        let guide = BoardGuidance(connection: client, settle: {})
        XCTAssertFalse(guide.isSupported)
        XCTAssertThrowsError(try guide.prepareSession(fen: initialFEN)) {
            XCTAssertEqual($0 as? BoardGuidanceError, .unsupportedBoard)
        }
        client.capabilities = [.readPosition, .controlLights]
        client.ready = false
        XCTAssertThrowsError(try guide.prepareSession(fen: initialFEN))
        client.ready = true
        XCTAssertThrowsError(try guide.prepareSession(fen: "invalid"))
        XCTAssertTrue(client.commands.isEmpty)
        XCTAssertNil(client.owner)
        XCTAssertThrowsError(try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)) {
            XCTAssertEqual($0 as? BoardGuidanceError, .sessionNotPrepared)
        }
    }

    @MainActor
    func testSensorPreparationRequiresFreshExactReadingAndCorrectsDifferences() async throws {
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: {})
        client.emit(.position(.initial)) // A pre-session event cannot satisfy preparation.
        try guide.prepareSession(fen: initialFEN)
        XCTAssertEqual(guide.state, .preparing)
        guard case .requestPosition = client.commands.first?.0 else { return XCTFail("No fresh reading requested") }
        client.emit(.position(e4))
        XCTAssertEqual(guide.differingSquares, [36, 52])
        XCTAssertEqual(client.lastLights, [36, 52])
        client.emit(.position(.initial))
        await expectState(guide) { $0 == .ready }
        XCTAssertEqual(client.lastLights, [])
    }

    @MainActor
    func testSensorMoveWaitsForTargetAndCompletesWithSensorEvidence() async throws {
        let (client, guide) = try await sensorSession()
        let before = client.commands.count
        let id = try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        XCTAssertEqual(client.commands.count, before + 2)
        XCTAssertEqual(client.lastLights, [36, 52])
        guard case .awaitingMove = guide.state else { return XCTFail("Must wait for physical placement") }
        client.emit(.commandConfirmed(id))
        client.emit(.position(.initial))
        guard case .awaitingMove = guide.state else { return XCTFail("An acknowledgment is not a physical reading") }
        client.emit(.position(e4))
        await expectState(guide) { if case .completed = $0 { true } else { false } }
        guard case .completed(let result) = guide.state else { return XCTFail("Missing completion") }
        XCTAssertEqual(result.request.id, id)
        XCTAssertEqual(result.request.expectedPosition, e4)
        XCTAssertEqual(result.evidence, .sensorPosition)
        XCTAssertEqual(client.lastLights, [])
    }

    @MainActor
    func testSensorGuidanceUpdatesAllDifferencesForCastlingWithoutApplyingChessRules() async throws {
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: {})
        let before = try BoardPosition(fen: "4k3/8/8/8/8/8/8/4K2R")
        let after = try BoardPosition(fen: "4k3/8/8/8/8/8/8/5RK1")
        try guide.prepareSession(fen: before.fen + " w K - 0 1")
        client.emit(.position(before))
        await expectState(guide) { $0 == .ready }
        try guide.guideMove(BoardMove(from: 60, to: 62), expectedPosition: after)
        client.emit(.position(before))
        XCTAssertEqual(guide.differingSquares, [60, 61, 62, 63])
        XCTAssertEqual(client.lastLights, [60, 61, 62, 63])
        client.emit(.position(after))
        await expectState(guide) { if case .completed = $0 { true } else { false } }
    }

    @MainActor
    func testMoveProtocolRequiresSessionConfirmationThenPhysicalReportAndAck() throws {
        let (client, guide) = try moveSession()
        let id = try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        client.emit(.commandConfirmed(UUID()))
        client.emit(.position(e4))
        client.emit(.commandConfirmed(id))
        guard case .awaitingMove = guide.state else { return XCTFail("Protocol acceptance must not complete a physical move") }
        client.emit(.move(try BoardMove(from: 52, to: 36)))
        guard case .completed(let result) = guide.state else { return XCTFail("Missing completion") }
        XCTAssertEqual(result.evidence, .reportedMove)
        XCTAssertTrue(guide.differingSquares.isEmpty)
        XCTAssertEqual(result.request.expectedPosition, e4)
    }

    @MainActor
    func testPhysicalReportMayPrecedeProtocolAcknowledgment() throws {
        let (client, guide) = try moveSession()
        let move = try BoardMove(from: 12, to: 28)
        let id = try guide.guideMove(move, expectedPosition: e5)
        client.emit(.move(move))
        guard case .awaitingMove = guide.state else { return XCTFail("Wait for the command acknowledgment too") }
        client.emit(.commandConfirmed(id))
        guard case .completed = guide.state else { return XCTFail("Both conditions have been met") }
    }

    @MainActor
    func testPromotionRequiresTheExpectedPieceChoice() throws {
        let (client, guide) = try moveSession()
        let move = try BoardMove(from: 8, to: 0, promotion: "n")
        let target = try BoardPosition(fen: "N6k/8/8/8/8/8/8/7K")
        let id = try guide.guideMove(move, expectedPosition: target)
        client.emit(.commandConfirmed(id))
        client.emit(.move(try BoardMove(from: 8, to: 0)))
        guard case .awaitingMove = guide.state else { return XCTFail("Promotion is incomplete until the piece is known") }
        client.emit(.move(move))
        guard case .completed(let result) = guide.state else { return XCTFail("No completed promotion") }
        XCTAssertEqual(result.request.move.promotion, "n")
    }

    @MainActor
    func testUnexpectedMoveFailsAndRequiresAnewSession() throws {
        let (client, guide) = try moveSession()
        try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        let wrong = try BoardMove(from: 51, to: 35)
        client.emit(.move(wrong))
        XCTAssertEqual(guide.state, .failed(.unexpectedMove(wrong)))
        XCTAssertNil(client.owner)
        XCTAssertThrowsError(try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4))
    }

    @MainActor
    func testCancellationIgnoresLateAcknowledgmentsAndPhysicalMoves() throws {
        let (client, guide) = try moveSession()
        let move = try BoardMove(from: 52, to: 36)
        let id = try guide.guideMove(move, expectedPosition: e4)
        guide.cancel()
        client.emit(.commandConfirmed(id))
        client.emit(.move(move))
        XCTAssertEqual(guide.state, .cancelled)
        XCTAssertNil(client.owner)
        XCTAssertEqual(client.endCount, 1)
        guide.cancel()
        XCTAssertEqual(client.endCount, 1)
    }

    @MainActor
    func testDisconnectOrProtocolTimeoutFailsAnActiveSession() throws {
        let (client, guide) = try moveSession()
        try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        client.ready = false
        client.emit(.connectionState(.failed("Protocol timeout")))
        XCTAssertEqual(guide.state, .failed(.connectionLost))
        XCTAssertNil(client.owner)
        XCTAssertThrowsError(try guide.prepareSession(fen: initialFEN))
    }

    @MainActor
    func testCommandFailureDoesNotLeaveASessionOwned() throws {
        let client = GuidanceStub(capabilities: [.sendMove, .receiveMoves, .loadPosition])
        let guide = BoardGuidance(connection: client, settle: {})
        client.failure = .invalidFEN
        XCTAssertThrowsError(try guide.prepareSession(fen: initialFEN))
        guard case .failed(.commandFailed) = guide.state else { return XCTFail("Missing command failure") }
        XCTAssertNil(client.owner)
    }

    @MainActor
    func testBusyOperationCannotBeReplacedAndAnotherGuideCannotAcquireSameConnection() throws {
        let (client, guide) = try moveSession()
        let another = BoardGuidance(connection: client, settle: {})
        XCTAssertThrowsError(try another.prepareSession(fen: initialFEN))
        let id = try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        XCTAssertThrowsError(try guide.guideMove(BoardMove(from: 12, to: 28), expectedPosition: e5)) {
            XCTAssertEqual($0 as? BoardGuidanceError, .busy)
        }
        XCTAssertThrowsError(try guide.prepareSession(fen: initialFEN))
        guard case .awaitingMove(let request) = guide.state else { return XCTFail("Request replaced") }
        XCTAssertEqual(request.id, id)
    }

    @MainActor
    func testCompletionSubscriberCanImmediatelySubmitNextMove() throws {
        let (client, guide) = try moveSession()
        let first = try BoardMove(from: 52, to: 36)
        let next = try BoardMove(from: 12, to: 28)
        let id = try guide.guideMove(first, expectedPosition: e4)
        var nextID: UUID?
        let subscription = guide.states.sink { state in
            if case .completed = state { nextID = try? guide.guideMove(next, expectedPosition: self.e5) }
        }
        client.emit(.commandConfirmed(id))
        client.emit(.move(first))
        guard case .awaitingMove(let request) = guide.state else { return XCTFail("Completion overwrote the next request") }
        XCTAssertEqual(request.id, nextID)
        XCTAssertEqual(request.move, next)
        var replayed: BoardGuidanceState?
        let replay = guide.states.prefix(1).sink { replayed = $0 }
        XCTAssertEqual(replayed, guide.state)
        withExtendedLifetime(replay) {}
        // The previous command's completion must not accept the new command.
        client.emit(.commandConfirmed(id))
        client.emit(.move(next))
        guard case .awaitingMove = guide.state else { return XCTFail("Old acknowledgment accepted") }
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testCancellationFromAwaitingStateSubscriberDoesNotSendTheCommand() throws {
        let (client, guide) = try moveSession()
        let before = client.commands.count
        let subscription = guide.states.sink { state in
            if case .awaitingMove = state { guide.cancel() }
        }
        try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        XCTAssertEqual(guide.state, .cancelled)
        XCTAssertEqual(client.commands.count, before)
        withExtendedLifetime(subscription) {}
    }

    @MainActor
    func testTransientSensorMatchIsNotCompletedAfterPositionChangesOrCancellation() async throws {
        let sleeper = GuidanceTestSleeper()
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: { await sleeper.wait() })
        try guide.prepareSession(fen: initialFEN)
        client.emit(.position(.initial))
        let started = XCTestExpectation(description: "settling began")
        await sleeper.onStart(started)
        await wait(started)
        client.emit(.position(e4))
        await sleeper.resume()
        XCTAssertEqual(guide.state, .preparing)
        guide.cancel()
        client.emit(.position(.initial))
        XCTAssertEqual(guide.state, .cancelled)
    }

    @MainActor
    func testRepeatedExactReadingsDoNotRestartTheSettleInterval() async throws {
        let sleeper = GuidanceTestSleeper()
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: { await sleeper.wait() })
        try guide.prepareSession(fen: initialFEN)
        client.emit(.position(.initial))
        let started = XCTestExpectation(description: "First settle interval")
        await sleeper.onStart(started)
        await wait(started)
        for _ in 0..<20 { client.emit(.position(.initial)) }
        let calls = await sleeper.calls
        XCTAssertEqual(calls, 1)
        await sleeper.resume()
        await expectState(guide) { $0 == .ready }
    }

    @MainActor
    func testObsoleteSettleTaskCannotCompleteANewerSettleInterval() async throws {
        let sleeper = GuidanceTestSleeper()
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: { await sleeper.wait() })
        try guide.prepareSession(fen: initialFEN)
        client.emit(.position(.initial))
        let first = XCTestExpectation(description: "First interval")
        await sleeper.onStart(first)
        await wait(first)
        client.emit(.position(e4))
        client.emit(.position(.initial))
        let second = XCTestExpectation(description: "New interval")
        await sleeper.onStart(second, call: 2)
        await wait(second)
        let premature = XCTestExpectation(description: "Obsolete timer must not complete")
        premature.isInverted = true
        let subscription = guide.states.filter { $0 == .ready }.sink { _ in premature.fulfill() }
        await sleeper.resume()
        let result = await XCTWaiter.fulfillment(of: [premature], timeout: 0.05)
        XCTAssertEqual(result, .completed)
        subscription.cancel()
        XCTAssertEqual(guide.state, .preparing)
        await sleeper.resume()
        await expectState(guide) { $0 == .ready }
    }

    @MainActor
    func testForegroundRefreshRequestsNewSensorDataButNeverResendsAMove() async throws {
        let (sensor, sensorGuide) = try await sensorSession()
        try sensorGuide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        let before = sensor.commands.count
        sensorGuide.refresh()
        XCTAssertEqual(sensor.commands.count, before + 1)
        guard case .requestPosition = sensor.commands.last?.0 else { return XCTFail("No fresh sensor request") }
        let (moveClient, moveGuide) = try moveSession()
        try moveGuide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        let moves = moveClient.commands.count
        moveGuide.refresh()
        XCTAssertEqual(moveClient.commands.count, moves, "A foreground transition cannot retry a move")
    }

    @MainActor
    func testObjectInvalidationCancellationDoesNotLeaveAStaleReplayedState() throws {
        let (client, guide) = try moveSession()
        let subscription = guide.objectWillChange.sink {
            if case .awaitingMove = guide.state { guide.cancel() }
        }
        let before = client.commands.count
        try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: e4)
        XCTAssertEqual(guide.state, .cancelled)
        XCTAssertEqual(client.commands.count, before)
        var replayed: BoardGuidanceState?
        let replay = guide.states.prefix(1).sink { replayed = $0 }
        XCTAssertEqual(replayed, .cancelled)
        withExtendedLifetime((subscription, replay)) {}
    }

    @MainActor
    func testAllSubscribersSeeCompletionBeforeTheNextRequest() throws {
        let (client, guide) = try moveSession()
        let first = try BoardMove(from: 52, to: 36)
        let next = try BoardMove(from: 12, to: 28)
        let firstID = try guide.guideMove(first, expectedPosition: e4)
        var observed: [BoardGuidanceState] = []
        let advance = guide.states.sink { state in
            if case .completed = state { _ = try? guide.guideMove(next, expectedPosition: self.e5) }
        }
        let observer = guide.states.sink { observed.append($0) }
        client.emit(.commandConfirmed(firstID))
        client.emit(.move(first))
        XCTAssertEqual(observed.count, 3)
        guard case .awaitingMove(let old) = observed[0],
              case .completed(let completion) = observed[1],
              case .awaitingMove(let following) = observed[2] else {
            return XCTFail("Subscribers received transitions out of order")
        }
        XCTAssertEqual(old.id, completion.request.id)
        XCTAssertEqual(following.move, next)
        withExtendedLifetime((advance, observer)) {}
    }

    @MainActor
    func testInconsistentTargetIsRejectedWithoutSendingOrReplacingTheReadySession() throws {
        let (client, guide) = try moveSession()
        let count = client.commands.count
        XCTAssertThrowsError(try guide.guideMove(BoardMove(from: 52, to: 36), expectedPosition: .initial)) {
            XCTAssertEqual($0 as? BoardGuidanceError, .inconsistentTarget)
        }
        XCTAssertEqual(guide.state, .ready)
        XCTAssertEqual(client.commands.count, count)
    }

    @MainActor
    func testUnsolicitedMoveBetweenRequestsInvalidatesThePreparedSession() throws {
        let (client, guide) = try moveSession()
        let unexpected = try BoardMove(from: 51, to: 35)
        client.emit(.move(unexpected))
        XCTAssertEqual(guide.state, .failed(.unexpectedMove(unexpected)))
        XCTAssertNil(client.owner)
    }

    @MainActor
    func testDroppingGuideSchedulesOwnerCleanup() async throws {
        let client = GuidanceStub(capabilities: [.sendMove, .receiveMoves, .loadPosition])
        let cleaned = XCTestExpectation(description: "Owner released on deinitialization")
        client.onEnd = { cleaned.fulfill() }
        var guide: BoardGuidance? = BoardGuidance(connection: client, settle: {})
        try guide?.prepareSession(fen: initialFEN)
        XCTAssertNotNil(client.owner)
        weak var weakGuide = guide
        guide = nil
        XCTAssertNil(weakGuide)
        await wait(cleaned)
        XCTAssertNil(client.owner)
    }

    @MainActor
    private func moveSession() throws -> (GuidanceStub, BoardGuidance) {
        let client = GuidanceStub(capabilities: [.sendMove, .receiveMoves, .loadPosition])
        let guide = BoardGuidance(connection: client, settle: {})
        try guide.prepareSession(fen: initialFEN)
        XCTAssertEqual(guide.state, .preparing)
        client.emit(.commandConfirmed(UUID()))
        XCTAssertEqual(guide.state, .preparing)
        let id = try XCTUnwrap(client.commands.first?.1)
        client.emit(.commandConfirmed(id))
        XCTAssertEqual(guide.state, .ready)
        return (client, guide)
    }
    @MainActor
    private func sensorSession() async throws -> (GuidanceStub, BoardGuidance) {
        let client = GuidanceStub(capabilities: [.readPosition, .controlLights])
        let guide = BoardGuidance(connection: client, settle: {})
        try guide.prepareSession(fen: initialFEN)
        client.emit(.position(.initial))
        await expectState(guide) { $0 == .ready }
        return (client, guide)
    }
    @MainActor
    private func expectState(_ guide: BoardGuidance, matches: @escaping (BoardGuidanceState) -> Bool) async {
        if matches(guide.state) { return }
        let expectation = XCTestExpectation(description: "Expected guidance state")
        let subscription = guide.states.filter(matches).prefix(1).sink { _ in expectation.fulfill() }
        await wait(expectation)
        withExtendedLifetime(subscription) {}
    }
    @MainActor
    private func wait(_ expectation: XCTestExpectation) async {
        let result = await XCTWaiter.fulfillment(of: [expectation], timeout: 2)
        XCTAssertEqual(result, .completed)
    }
}

@MainActor
private final class GuidanceStub: GuidanceConnection {
    var ready = true
    var capabilities: BoardCapabilities
    var owner: UUID?
    var failure: ConnectError?
    var commands: [(BoardCommand, UUID)] = []
    var endCount = 0
    var onEnd: (() -> Void)?
    private let subject = PassthroughSubject<BoardEvent, Never>()
    var events: AnyPublisher<BoardEvent, Never> { subject.eraseToAnyPublisher() }
    var lastLights: [Int]? {
        for (command, _) in commands.reversed() { if case .setLights(let squares) = command { return squares } }
        return nil
    }
    init(capabilities: BoardCapabilities) { self.capabilities = capabilities }
    func emit(_ event: BoardEvent) { subject.send(event) }
    func acquireGuidance(owner: UUID) throws {
        guard self.owner == nil || self.owner == owner else { throw ConnectError.busy }
        self.owner = owner
    }
    func sendGuidance(_ command: BoardCommand, id: UUID, owner: UUID) throws {
        guard self.owner == owner else { throw ConnectError.busy }
        if let failure { throw failure }
        commands.append((command, id))
    }
    func endGuidance(owner: UUID) { if self.owner == owner { endCount += 1; self.owner = nil; onEnd?() } }
}

private actor GuidanceTestSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var observers: [(Int, XCTestExpectation)] = []
    private(set) var calls = 0
    func onStart(_ expectation: XCTestExpectation, call: Int = 1) {
        if calls >= call { expectation.fulfill() } else { observers.append((call, expectation)) }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
            calls += 1
            for (count, expectation) in observers where count <= calls { expectation.fulfill() }
            observers.removeAll { $0.0 <= calls }
        }
    }
    func resume() { if !continuations.isEmpty { continuations.removeFirst().resume() } }
}
