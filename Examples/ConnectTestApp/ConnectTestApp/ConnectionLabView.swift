import SwiftUI
import ChessBoardConnect

/// Renders presentation state; actions and subscriptions belong to the view model.
struct ConnectionLabView: View {
    @StateObject private var model: ConnectionLabViewModel
    @Environment(\.scenePhase) private var phase

    init(configuration: LabConfiguration) {
        _model = StateObject(wrappedValue: ConnectionLabViewModel(
            configuration: configuration, client: LiveLabBoardClient()
        ))
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                if !model.board.connectedOrConnecting { discoverySection }
                capabilitiesSection
                if model.supports(.readPosition) { positionSection }
                if model.supports(.controlLights) { lightsSection }
                if model.supports(.loadPosition) { loadPositionSection }
                if model.supports(.sendMove) { sendMoveSection }
                if let move = model.lastMoveDescription {
                    Section("Last reported move") { Text(move) }
                }
                if !model.commandResult.isEmpty {
                    Section { Text(model.commandResult).font(.caption).foregroundStyle(.secondary) }
                }
                diagnosticsSection
            }
            .navigationTitle(model.configuration.title)
            .onDisappear { model.stop() }
            .sheet(item: $model.exportedReport, onDismiss: { model.reportDismissed() }) { report in
                ReportShareSheet(url: report.url)
            }
            .alert("Action failed", isPresented: Binding(
                get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
            )) {
                Button("Close", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
            .onChange(of: phase) { _, phase in
                if phase == .active { model.sceneDidBecomeActive() }
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            Text("Test board connectivity, positions, moves, and lights.")
                .font(.callout).foregroundStyle(.secondary)
            Label(model.board.status, systemImage: model.board.ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
            LabeledContent("Status", value: model.stateName)
            LabeledContent("Selected board", value: model.selectedName)
            HStack {
                Button(model.configuration.searchTitle) { model.search() }.disabled(!model.canSearch)
                if model.board.scanning { Button("Stop") { model.stopScan() } }
                if model.board.connectedOrConnecting {
                    Button("Disconnect") { model.disconnect() }
                } else if model.board.canReconnect {
                    Button("Reconnect") { model.reconnect() }
                }
            }.buttonStyle(.bordered)
            Text(model.configuration.instructions).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var discoverySection: some View {
        Section("Boards found · \(model.board.devices.count)") {
            if model.board.devices.isEmpty {
                Text(model.board.scanning ? "Scanning for compatible devices…" : "Search to select your board.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.board.devices) { device in
                Button { model.select(device) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text("\(device.rssi == 127 ? "Available through iOS" : "\(device.rssi) dBm") · \(device.id.uuidString)")
                            .font(.caption2.monospaced())
                    }
                }
            }
        }
    }

    private var capabilitiesSection: some View {
        Section("Connected board capabilities") {
            capability("Read positions", .readPosition)
            capability("Receive moves", .receiveMoves)
            capability("Control lights", .controlLights)
            capability("Send moves", .sendMove)
            capability("Load positions", .loadPosition)
            Text("Capabilities are reported by the driver. Verify them on the physical board.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var positionSection: some View {
        Section("Received position · White at the bottom") {
            if let position = model.board.position {
                BoardPositionView(position: position)
                Text(position.fen).font(.caption.monospaced()).textSelection(.enabled)
            } else {
                Text("No current reading").foregroundStyle(.secondary)
            }
            LabeledContent("Readings this session", value: "\(model.readingCount)")
            if let lastReading = model.lastReading {
                LabeledContent("Last reading", value: lastReading.formatted(.dateTime.hour().minute().second().locale(Locale(identifier: "en_US_POSIX"))))
            }
            Button("Request position") { model.refresh() }
            Text("The position above comes from the board. It is not a simulation or a target position.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var lightsSection: some View {
        Section("Lights") {
            TextField("Squares, for example e2 e4", text: $model.lightSquares)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            HStack {
                Button("Turn on") { model.turnLightsOn() }
                Button("Turn all off") { model.turnLightsOff() }
            }.buttonStyle(.bordered)
            Text("Check the physical board to confirm that the selected squares light up.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var loadPositionSection: some View {
        Section("Load position") {
            TextField("Full FEN", text: $model.fen, axis: .vertical)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Start study session with FEN") { model.loadPosition() }
        }
    }

    private var sendMoveSection: some View {
        Section("Send move") {
            Text("Load a position first. Wait for the board confirmation in the status before sending another command.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("From", text: $model.moveFrom).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("To", text: $model.moveTo).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Promotion", selection: $model.promotion) {
                Text("None").tag("")
                Text("Queen").tag("q")
                Text("Rook").tag("r")
                Text("Bishop").tag("b")
                Text("Knight").tag("n")
            }
            Button("Send") { model.sendMove() }
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            TextField("Board firmware (optional)", text: $model.firmware)
            Button { model.exportReport(metadata: .current) } label: {
                Label(model.exporting ? "Preparing report…" : "Export log", systemImage: "square.and.arrow.up")
            }.disabled(!model.canExport)
            Button("Clear logs", systemImage: "trash") { model.clearLogs() }.disabled(model.board.logs.isEmpty)
            Text("Exports the last 200 events, including TX/RX messages, and the device information shown in the report.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Clearing logs keeps the connection and readings. New events are recorded as they arrive.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(model.board.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption2.monospaced()).textSelection(.enabled)
            }
        }
    }

    private func capability(_ title: String, _ capability: BoardCapabilities) -> some View {
        LabeledContent(title, value: model.capabilityDescription(capability))
    }
}
