import Foundation
import Combine
import XCTest
import ChessBoardConnect

final class GuidanceLabTests: XCTestCase {
    @MainActor
    func testSameActionsForwardTheMoveAndTargetWithoutBoardNameBranches() throws {
        let client = GuidedLabClient()
        let model = ConnectionLabViewModel(configuration: .nearbyBoards, client: client)
        client.emit(.ready(true))
        XCTAssertTrue(model.hasGuidance)
        XCTAssertTrue(model.canPrepareGuidance)
        model.prepareGuidance()
        XCTAssertEqual(client.guide.initialFEN, model.fen)
        XCTAssertEqual(model.guidanceState, .preparing)
        XCTAssertFalse(model.canGuideMove)
        client.guide.setState(.ready)
        XCTAssertTrue(model.canGuideMove)
        model.guideMove()
        XCTAssertEqual(client.guide.requests.count, 1)
        let request = try XCTUnwrap(client.guide.requests.first)
        XCTAssertEqual(request.move, try BoardMove(from: 52, to: 36))
        XCTAssertEqual(request.expectedPosition.fen, model.expectedFEN)
        XCTAssertFalse(model.canGuideMove)
        model.cancelGuidance()
        XCTAssertEqual(model.guidanceState, .cancelled)
        XCTAssertEqual(client.guide.cancelCount, 1)
    }

    @MainActor
    func testInvalidTargetsAndCoordinatesDoNotReachTheGuide() {
        let client = GuidedLabClient()
        let model = ConnectionLabViewModel(configuration: .chessUp, client: client)
        model.expectedFEN = "invalid"
        model.guideMove()
        XCTAssertEqual(model.errorMessage, BoardGuidanceError.invalidPosition.errorDescription)
        model.expectedFEN = BoardPosition.initial.fen
        model.moveFrom = "z9"
        model.guideMove()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(client.guide.requests.isEmpty)
    }

    @MainActor
    func testGuidanceOwnershipRoutesForegroundRefreshAndShowsDifferences() {
        let client = GuidedLabClient()
        let model = ConnectionLabViewModel(configuration: .chessUp, client: client)
        client.emit(.capabilities([.readPosition, .controlLights]))
        client.emit(.ready(true))
        client.emit(.guidanceActive(true))
        client.emit(.guidanceDifferences([36, 52]))
        model.sceneDidBecomeActive()
        XCTAssertEqual(client.guide.refreshCount, 1)
        XCTAssertTrue(client.commands.isEmpty)
        model.turnLightsOn()
        XCTAssertEqual(model.errorMessage, ConnectError.busy.errorDescription)
        XCTAssertTrue(client.commands.isEmpty)
        XCTAssertEqual(model.guidanceDifferenceDescription, "e4 e2")
        model.stop()
        XCTAssertEqual(client.guide.cancelCount, 1)
        XCTAssertEqual(client.disconnectCount, 1)
    }
}

@MainActor
private final class LabGuideSpy: LabGuiding {
    var state: BoardGuidanceState = .idle
    var isSupported = true
    private let subject = CurrentValueSubject<BoardGuidanceState, Never>(.idle)
    var states: AnyPublisher<BoardGuidanceState, Never> { subject.eraseToAnyPublisher() }
    var differences: AnyPublisher<[Int], Never> { Just([]).eraseToAnyPublisher() }
    var initialFEN: String?
    var requests: [BoardGuidanceRequest] = []
    var cancelCount = 0
    var refreshCount = 0
    func setState(_ state: BoardGuidanceState) { self.state = state; subject.send(state) }
    func prepareSession(fen: String) throws { initialFEN = fen; setState(.preparing) }
    func guideMove(_ move: BoardMove, expectedPosition: BoardPosition) throws -> UUID {
        let request = BoardGuidanceRequest(move: move, expectedPosition: expectedPosition)
        requests.append(request)
        setState(.awaitingMove(request))
        return request.id
    }
    func refresh() { refreshCount += 1 }
    func cancel() { cancelCount += 1; setState(.cancelled) }
}

@MainActor
private final class GuidedLabClient: LabBoardClient {
    let guide = LabGuideSpy()
    var guidance: (any LabGuiding)? { guide }
    private let subject = PassthroughSubject<LabBoardEvent, Never>()
    var events: AnyPublisher<LabBoardEvent, Never> {
        Publishers.Merge(subject, guide.states.map(LabBoardEvent.guidance)).eraseToAnyPublisher()
    }
    var commands: [BoardCommand] = []
    var disconnectCount = 0
    func emit(_ event: LabBoardEvent) { subject.send(event) }
    func scan() {}
    func findConnectedBoards(namePrefix: String?) {}
    func stopScan() {}
    func connect(_ id: UUID) throws {}
    func disconnect() { disconnectCount += 1 }
    func reconnect() throws {}
    func send(_ command: BoardCommand) throws { commands.append(command) }
    func clearLogs() {}
}
