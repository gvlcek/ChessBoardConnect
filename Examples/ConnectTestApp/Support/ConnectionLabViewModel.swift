import Foundation
import Combine
import ChessBoardConnect

struct ReportMetadata {
    let appVersion: String
    let build: String
    let device: String
}

struct PreparedReport: Identifiable {
    let id = UUID()
    let url: URL
}

protocol LabReportExporting: Sendable {
    func prepare(_ snapshot: ReportSnapshot) async throws -> URL
    func remove(_ url: URL) async
}

struct FileLabReportExporter: LabReportExporting {
    func prepare(_ snapshot: ReportSnapshot) async throws -> URL { try await ReportExport.prepare(snapshot) }
    func remove(_ url: URL) async { await ReportExport.remove(url) }
}

/// Presentation state and actions only: hardware protocols remain inside the library.
@MainActor
final class ConnectionLabViewModel: ObservableObject {
    let configuration: LabConfiguration
    @Published private(set) var board = LabBoardState()
    @Published private(set) var selectedName = "Not selected"
    @Published private(set) var commandResult = ""
    @Published private(set) var lastReading: Date?
    @Published private(set) var readingCount = 0
    @Published private(set) var exporting = false
    @Published var errorMessage: String?
    @Published var exportedReport: PreparedReport?
    @Published var lightSquares = "e2 e4"
    @Published var moveFrom = "e2"
    @Published var moveTo = "e4"
    @Published var promotion = ""
    @Published var fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    @Published var firmware = ""
    @Published var expectedFEN = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR"
    @Published private(set) var guidanceState: BoardGuidanceState = .idle
    @Published private(set) var guidanceDifferences: [Int] = []

    private let client: any LabBoardClient
    private let guidance: (any LabGuiding)?
    private let exporter: any LabReportExporting
    private let now: () -> Date
    private var subscription: AnyCancellable?
    private var exportTask: Task<Void, Never>?
    private var exportID: UUID?
    private var reportToRemove: URL?

    init(configuration: LabConfiguration, client: any LabBoardClient,
         exporter: any LabReportExporting = FileLabReportExporter(), now: @escaping () -> Date = Date.init) {
        self.configuration = configuration
        self.client = client
        self.guidance = client.guidance
        self.exporter = exporter
        self.now = now
        subscription = client.events.sink { [weak self] in self?.receive($0) }
    }

    var canSearch: Bool { !board.scanning && !board.connectedOrConnecting }
    var hasGuidance: Bool { guidance != nil }
    var canPrepareGuidance: Bool {
        guard board.ready, guidance?.isSupported == true else { return false }
        return switch guidanceState { case .preparing, .awaitingMove: false; default: true }
    }
    var canGuideMove: Bool { board.ready && guidanceState.canGuideMove }
    var guidanceDescription: String {
        switch guidanceState {
        case .idle: "Not started"
        case .preparing: "Preparing session · waiting for board confirmation"
        case .ready: "Ready to guide a move"
        case .awaitingMove(let request): "Waiting for \(Self.describe(request.move))"
        case .completed(let result): result.evidence == .sensorPosition ? "Completed · sensor position matched" : "Completed · physical move reported"
        case .cancelled: "Cancelled"
        case .failed(let error): error.errorDescription ?? "Guidance failed"
        }
    }
    var guidanceDifferenceDescription: String {
        guidanceDifferences.map(BoardPosition.name).joined(separator: " ")
    }
    func prepareGuidance() {
        perform {
            guard let guidance else { throw BoardGuidanceError.unsupportedBoard }
            try guidance.prepareSession(fen: fen)
        }
    }
    func guideMove() {
        perform {
            guard let guidance else { throw BoardGuidanceError.unsupportedBoard }
            let target: BoardPosition
            do { target = try BoardPosition(fen: expectedFEN) }
            catch { throw BoardGuidanceError.invalidPosition }
            try guidance.guideMove(validatedMove(), expectedPosition: target)
        }
    }
    func cancelGuidance() { guidance?.cancel() }

    var canExport: Bool { !exporting && reportToRemove == nil }

    func supports(_ capability: BoardCapabilities) -> Bool {
        board.ready && board.capabilities.contains(capability)
    }

    func capabilityDescription(_ capability: BoardCapabilities) -> String {
        !board.ready ? "Not connected" : supports(capability) ? "Available" : "Unavailable"
    }

    var stateName: String {
        switch board.connection {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .discovered: "Scan complete"
        case .connecting: "Connecting"
        case .discoveringServices: "Discovering services"
        case .connected: "Connected"
        case .receivingPosition: "Receiving positions"
        case .disconnected: "Disconnected"
        case .failed(let message): "Error: \(message)"
        }
    }

    var lastMoveDescription: String? {
        board.lastMove.map { Self.describe($0) }
    }

    func search() {
        guard canSearch else { return }
        switch configuration.discovery {
        case .advertisements: client.scan()
        case .systemConnected(let prefix): client.findConnectedBoards(namePrefix: prefix)
        }
    }

    func stopScan() { client.stopScan() }
    func disconnect() { client.disconnect() }
    func reconnect() { perform { try client.reconnect() } }
    func select(_ device: BoardDevice) {
        perform {
            try client.connect(device.id)
            selectedName = device.name
        }
    }
    func clearLogs() { client.clearLogs() }
    func refresh() { perform { try require(.readPosition); try client.send(.requestPosition) } }
    func sceneDidBecomeActive() {
        if board.guidanceActive { guidance?.refresh() }
        else if supports(.readPosition) { refresh() }
    }

    func turnLightsOn() {
        perform {
            try require(.controlLights)
            let names = lightSquares.lowercased().split { $0.isWhitespace || $0 == "," }
            let indices = names.compactMap { BoardPosition.index(String($0)) }
            guard !names.isEmpty, indices.count == names.count else { throw LabInputError.invalidSquares }
            try client.send(.setLights(indices))
        }
    }
    func turnLightsOff() { perform { try require(.controlLights); try client.send(.setLights([])) } }
    func loadPosition() { perform { try require(.loadPosition); try client.send(.loadPosition(fen)) } }
    func sendMove() {
        perform {
            try require(.sendMove)
            try client.send(.sendMove(validatedMove()))
        }
    }

    private func validatedMove() throws -> BoardMove {
        guard let from = BoardPosition.index(moveFrom.lowercased()),
              let to = BoardPosition.index(moveTo.lowercased()),
              promotion.isEmpty || (promotion.count == 1 && "qrbn".contains(promotion)) else {
            throw LabInputError.invalidSquares
        }
        return try BoardMove(from: from, to: to, promotion: promotion.first)
    }

    func exportReport(metadata: ReportMetadata) {
        guard canExport else { return }
        let snapshot = ReportSnapshot(fields: [
            "ChessBoardConnect · ConnectTestApp \(metadata.appVersion) (\(metadata.build))",
            "Date: \(now().formatted(.iso8601))",
            "Device: \(metadata.device)",
            "Selected board: \(selectedName)",
            "Firmware: \(firmware.isEmpty ? "Not provided" : firmware)",
            "Status: \(board.status)",
            "Capabilities: \(board.capabilities.rawValue)",
            "Last reported move: \(lastMoveDescription ?? "None")",
            "Current position: \(board.position?.fen ?? "No reading")",
            "Readings: \(readingCount)",
            "Guidance: \(guidanceDescription)"
        ], logs: board.logs)
        let id = UUID()
        exportID = id
        exporting = true
        let exporter = self.exporter
        exportTask = Task { [weak self] in
            defer {
                if self?.exportID == id {
                    self?.exporting = false
                    self?.exportTask = nil
                }
            }
            do {
                let url = try await exporter.prepare(snapshot)
                guard !Task.isCancelled, self?.exportID == id else {
                    await exporter.remove(url)
                    return
                }
                self?.reportToRemove = url
                self?.exportedReport = PreparedReport(url: url)
            } catch {
                if !Task.isCancelled, self?.exportID == id { self?.errorMessage = error.localizedDescription }
            }
        }
    }

    func reportDismissed() {
        exportedReport = nil
        if let url = reportToRemove {
            reportToRemove = nil
            let exporter = self.exporter
            Task { await exporter.remove(url) }
        }
    }

    /// Called when this screen is removed, including configuration changes.
    func stop() {
        exportID = nil
        exportTask?.cancel()
        exportTask = nil
        exporting = false
        reportDismissed()
        guidance?.cancel()
        client.stopScan()
        client.disconnect()
    }

    private func require(_ capability: BoardCapabilities) throws {
        guard board.ready else { throw ConnectError.notConnected }
        guard !board.guidanceActive else { throw ConnectError.busy }
        guard supports(capability) else { throw ConnectError.unsupportedCapability }
    }
    private func perform(_ action: () throws -> Void) {
        errorMessage = nil
        do {
            try action()
            commandResult = "Action requested. Queued commands do not confirm physical execution: check the board and its response."
        } catch {
            commandResult = "The action failed."
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
    private func receive(_ event: LabBoardEvent) {
        switch event {
        case .devices(let value): board.devices = value
        case .state(let value):
            if value == .connecting { readingCount = 0; lastReading = nil }
            board.connection = value
        case .status(let value): board.status = value
        case .position(let value):
            board.position = value
            if value != nil { lastReading = now(); readingCount += 1 }
            else { lastReading = nil }
        case .move(let value): board.lastMove = value
        case .capabilities(let value): board.capabilities = value
        case .ready(let value): board.ready = value
        case .scanning(let value): board.scanning = value
        case .canReconnect(let value): board.canReconnect = value
        case .logs(let value): board.logs = value
        case .guidance(let value): guidanceState = value
        case .guidanceDifferences(let value): guidanceDifferences = value
        case .guidanceActive(let value): board.guidanceActive = value
        }
    }
    private static func describe(_ move: BoardMove) -> String {
        "\(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))\(move.promotion.map(String.init) ?? "")"
    }
}

private enum LabInputError: LocalizedError {
    case invalidSquares
    var errorDescription: String? { "Enter valid squares from a1 to h8. For lights, separate squares with spaces or commas. Promotion must be q, r, b, n, or empty." }
}
