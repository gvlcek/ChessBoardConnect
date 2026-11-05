import SwiftUI
import ChessBoardConnect

/// This app consumes only the library's public interface, just like any host app.
struct ConnectionLabView: View {
    @StateObject private var connect = BoardConnect()
    @Environment(\.scenePhase) private var phase
    @State private var selectedName = "Not selected"
    @State private var lightSquares = "e2 e4"
    @State private var moveFrom = "e2"
    @State private var moveTo = "e4"
    @State private var promotion = ""
    @State private var fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
    @State private var commandResult = ""
    @State private var errorMessage: String?
    @State private var lastReading: Date?
    @State private var readingCount = 0
    @State private var firmware = ""
    let chessUpOnly: Bool
    init(chessUpOnly: Bool = false) { self.chessUpOnly = chessUpOnly }
    private let glyphs: [Character: String] = ["K":"♔", "Q":"♕", "R":"♖", "B":"♗", "N":"♘", "P":"♙", "k":"♚", "q":"♛", "r":"♜", "b":"♝", "n":"♞", "p":"♟"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Test board connectivity and data without opening Chess Dex.")
                        .font(.callout).foregroundStyle(.secondary)
                    Label(connect.status, systemImage: connect.ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    LabeledContent("Status", value: stateName)
                    LabeledContent("Selected board", value: selectedName)
                    HStack {
                        Button(chessUpOnly ? "Find ChessUp" : "Scan") {
                            if chessUpOnly { connect.findConnectedBoards(namePrefix: "ChessUp") } else { connect.scan() }
                        }
                            .disabled(connect.scanning || connect.connectedOrConnecting)
                        if connect.scanning { Button("Stop") { connect.stopScan() } }
                        if connect.connectedOrConnecting {
                            Button("Disconnect") { connect.disconnect() }
                        } else if connect.canReconnect {
                            Button("Reconnect") { perform { try connect.reconnect() } }
                        }
                    }.buttonStyle(.bordered)
                    Text(chessUpOnly ? "Connect using the official ChessUp app, return here, and tap Find ChessUp. After connecting, send a full FEN below to start study mode." : "Turn on the board and disconnect other apps. The first scan requests Bluetooth permission.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Connection") }

                if !connect.connectedOrConnecting {
                    Section("Boards found · \(connect.devices.count)") {
                        if connect.devices.isEmpty {
                            Text(connect.scanning ? "Scanning for compatible devices…" : "Search to select your board.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(connect.devices) { device in
                            Button {
                                perform {
                                    try connect.connect(device.id)
                                    selectedName = device.name
                                    commandResult = ""
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.headline)
                                    Text("\(device.rssi == 127 ? "Available through iOS" : "\(device.rssi) dBm") · \(device.id.uuidString)").font(.caption2.monospaced())
                                }
                            }
                        }
                    }
                }

                Section("Connected board capabilities") {
                    capability("Read positions", .readPosition)
                    capability("Receive moves", .receiveMoves)
                    capability("Control lights", .controlLights)
                    capability("Send moves", .sendMove)
                    capability("Load positions", .loadPosition)
                    Text("Capabilities are reported by the driver. Verify them on the physical board.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if !chessUpOnly {
                    Section("Received position · White at the bottom") {
                        if let position = connect.position {
                            boardGrid(position)
                            Text(position.fen).font(.caption.monospaced()).textSelection(.enabled)
                        } else {
                            Text("No current reading").foregroundStyle(.secondary)
                        }
                        LabeledContent("Readings this session", value: "\(readingCount)")
                        if let lastReading {
                            LabeledContent("Last reading", value: lastReading.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "en_US_POSIX"))))
                        }
                        Button("Request position") { perform { try connect.refresh() } }
                            .disabled(!supports(.readPosition))
                        Text("The position above comes from the board. It is not a simulation or a target position.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Lights") {
                        TextField("Squares, for example e2 e4", text: $lightSquares)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        HStack {
                            Button("Turn on") {
                                perform {
                                    let names = lightSquares.lowercased().split { $0.isWhitespace || $0 == "," }
                                    let indices = names.compactMap { BoardPosition.index(String($0)) }
                                    guard !names.isEmpty, indices.count == names.count else { throw LabError.invalidSquares }
                                    try connect.showLights(indices)
                                }
                            }
                            Button("Turn all off") { perform { try connect.showLights([]) } }
                        }.buttonStyle(.bordered).disabled(!supports(.controlLights))
                        Text("Check the physical board to confirm that the selected squares light up.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if supports(.loadPosition) {
                    Section("Load position") {
                        TextField("Full FEN", text: $fen, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Start study session with FEN") { perform { try connect.send(.loadPosition(fen)) } }
                    }
                }
                if supports(.sendMove) {
                    Section("Send move") {
                        Text("Load a position first. Wait for the board confirmation in the status before sending another command.").font(.caption).foregroundStyle(.secondary)
                        TextField("From", text: $moveFrom).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("To", text: $moveTo).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Picker("Promotion", selection: $promotion) {
                            Text("None").tag("")
                            Text("Queen").tag("q")
                            Text("Rook").tag("r")
                            Text("Bishop").tag("b")
                            Text("Knight").tag("n")
                        }
                        Button("Send") {
                            perform {
                                guard let from = BoardPosition.index(moveFrom.lowercased()), let to = BoardPosition.index(moveTo.lowercased()) else { throw LabError.invalidSquares }
                                try connect.send(.sendMove(BoardMove(from: from, to: to, promotion: promotion.first)))
                            }
                        }
                    }
                }
                if let move = connect.lastMove {
                    Section("Last reported move") {
                        Text("\(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))\(move.promotion.map(String.init) ?? "")")
                    }
                }
                if !commandResult.isEmpty {
                    Section { Text(commandResult).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Diagnostics") {
                    TextField("Board firmware (optional)", text: $firmware)
                    ShareLink(item: diagnosticReport) {
                        Label("Export log", systemImage: "square.and.arrow.up")
                    }
                    Button("Clear logs", systemImage: "trash") { connect.clearLogs() }
                        .disabled(connect.logs.isEmpty)
                    Text("Exports the last 200 events, including TX/RX messages, and the device information shown in the report.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Clearing logs keeps the connection and readings. New events are recorded as they arrive.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(connect.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle(chessUpOnly ? "ChessUp Test" : "Connect Test")
            .onDisappear { connect.disconnect() }
            .alert("Action failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Close", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onReceive(connect.$position) { position in
                if position != nil { lastReading = Date(); readingCount += 1 }
                else { lastReading = nil }
            }
            .onChange(of: connect.state) { _, state in
                if state == .connecting { readingCount = 0; lastReading = nil }
            }
            .onChange(of: phase) { _, phase in
                if phase == .active && supports(.readPosition) {
                    perform { try connect.refresh() }
                }
            }
        }
    }
    private func supports(_ capability: BoardCapabilities) -> Bool {
        connect.ready && connect.capabilities.contains(capability)
    }
    private func capability(_ title: String, _ capability: BoardCapabilities) -> some View {
        LabeledContent(title, value: !connect.ready ? "Not connected" : supports(capability) ? "Available" : "Unavailable")
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            commandResult = "Action requested. Queued commands do not confirm physical execution: check the board and its response."
        } catch {
            commandResult = "The action failed."
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
    private var stateName: String {
        switch connect.state {
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
    private var diagnosticReport: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return """
        ChessBoardConnect · ConnectTestApp \(version) (\(build))
        Date: \(Date().formatted(.iso8601))
        Device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Selected board: \(selectedName)
        Firmware (entered manually): \(firmware.isEmpty ? "Not provided" : firmware)
        Status: \(stateName)
        Capabilities: \(connect.capabilities.rawValue)
        Last reported move: \(connect.lastMove.map { BoardPosition.name($0.from) + BoardPosition.name($0.to) + ($0.promotion.map(String.init) ?? "") } ?? "None")
        Current position: \(connect.position?.fen ?? "No reading")
        Readings: \(readingCount)

        \(connect.logs.joined(separator: "\n"))
        """
    }
    private func boardGrid(_ position: BoardPosition) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 8), spacing: 0) {
            ForEach(0..<64, id: \.self) { index in
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill((index / 8 + index % 8).isMultiple(of: 2) ? Color(red: 0.9, green: 0.86, blue: 0.76) : Color(red: 0.43, green: 0.54, blue: 0.44))
                    Text(glyphs[position.squares[index]] ?? "").font(.system(size: 29)).foregroundStyle(.black)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(BoardPosition.name(index)).font(.system(size: 8)).foregroundStyle(.black.opacity(0.65)).padding(2)
                }.aspectRatio(1, contentMode: .fit)
                    .accessibilityLabel("\(BoardPosition.name(index)): \(String(position.squares[index]))")
            }
        }.clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
private enum LabError: LocalizedError {
    case invalidSquares
    var errorDescription: String? { "Enter squares from a1 to h8, separated by spaces or commas. For example: e2 e4." }
}
