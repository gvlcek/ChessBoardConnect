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
    @State private var fen = ""
    @State private var commandResult = ""
    @State private var errorMessage: String?
    @State private var lastReading: Date?
    @State private var readingCount = 0
    @State private var firmware = ""
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
                        Button("Scan") { connect.scan() }
                            .disabled(connect.scanning || connect.connectedOrConnecting)
                        if connect.scanning { Button("Stop") { connect.stopScan() } }
                        if connect.connectedOrConnecting {
                            Button("Disconnect") { connect.disconnect() }
                        } else if connect.canReconnect {
                            Button("Reconnect") { perform { try connect.reconnect() } }
                        }
                    }.buttonStyle(.bordered)
                    Text("Turn on the board and disconnect other apps. The first scan requests Bluetooth permission.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Connection") }

                if !connect.connectedOrConnecting {
                    Section("Boards found · \(connect.devices.count)") {
                        if connect.devices.isEmpty {
                            Text(connect.scanning ? "Scanning for compatible devices…" : "Start a scan to select your board.")
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
                                    Text("\(device.rssi) dBm · \(device.id.uuidString)").font(.caption2.monospaced())
                                }
                            }
                        }
                    }
                }

                Section("Connected board capabilities") {
                    capability("Read positions", .readPosition)
                    capability("Control lights", .controlLights)
                    capability("Send moves", .sendMove)
                    capability("Load positions", .loadPosition)
                    Text("Capabilities are reported by the driver. Verify them on the physical board.")
                        .font(.caption).foregroundStyle(.secondary)
                }

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

                if supports(.sendMove) {
                    Section("Send move") {
                        TextField("From", text: $moveFrom).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("To", text: $moveTo).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Send") {
                            perform {
                                guard let from = BoardPosition.index(moveFrom.lowercased()), let to = BoardPosition.index(moveTo.lowercased()) else { throw LabError.invalidSquares }
                                try connect.send(.sendMove(BoardMove(from: from, to: to)))
                            }
                        }
                    }
                }
                if supports(.loadPosition) {
                    Section("Load position") {
                        TextField("Full FEN", text: $fen, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Send position") { perform { try connect.send(.loadPosition(fen)) } }
                    }
                }
                if let move = connect.lastMove {
                    Section("Last reported move") {
                        Text("\(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))")
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
                    Text("Exports the last 200 events, including TX/RX messages, and the device information shown in the report.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(connect.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Connect Test")
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

/// Metadata inspection without any game driver, characteristic reads or commands.
struct BLEDiagnosticLabView: View {
    @StateObject private var diagnostics = BoardDiagnostics()
    @State private var filter = ""
    @State private var firmware = ""
    @State private var notes = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Driver-independent discovery") {
                    Text("Use this mode to find ChessUp or other BLE devices before a board driver exists.")
                    Text("Scans all nearby BLE advertisements. Inspect only your board. This mode discovers service metadata; it does not read values, subscribe to notifications, or send board commands.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label(diagnostics.status, systemImage: diagnostics.inspectionCompleted ? "checkmark.circle" : "antenna.radiowaves.left.and.right")
                    HStack {
                        Button("Scan all BLE") { diagnostics.scan() }
                            .disabled(diagnostics.state.isScanning || diagnostics.state.connectionActive)
                        if diagnostics.state.isScanning {
                            Button("Stop") { diagnostics.stopScan() }
                        }
                        if diagnostics.state.connectionActive {
                            Button("Disconnect") { diagnostics.disconnect() }
                        }
                    }.buttonStyle(.bordered)
                    Text("For ChessUp: fully close the official app on nearby devices, restart the board, leave it on the home screen, and scan. The Wi-Fi icon alone does not tell us whether BLE is advertising.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Nearby devices · \(diagnostics.devices.count)") {
                    TextField("Filter by name (optional)", text: $filter)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("The filter affects this list only. Clear it to see unnamed devices too.")
                        .font(.caption).foregroundStyle(.secondary)
                    if visibleDevices.isEmpty {
                        Text("No matching advertisements received. An empty scan does not prove that Bluetooth is disabled.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visibleDevices) { device in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(.headline)
                            Text(device.id.uuidString).font(.caption2.monospaced()).textSelection(.enabled)
                            Text("RSSI: \(device.rssi == 127 ? "Unavailable" : "\(device.rssi) dBm") · Connectable: \(connectableText(device.isConnectable))")
                                .font(.caption)
                            Text("Advertised services: \(device.advertisedServices.isEmpty ? "None advertised" : device.advertisedServices.joined(separator: ", "))")
                                .font(.caption2.monospaced()).textSelection(.enabled)
                            Button("Select for report") {
                                do { try diagnostics.selectForReport(device.id) }
                                catch { errorMessage = error.localizedDescription }
                            }.disabled(diagnostics.state.connectionActive)
                            Button("Inspect GATT") {
                                do { try diagnostics.inspect(device.id) }
                                catch { errorMessage = error.localizedDescription }
                            }
                            .disabled(diagnostics.state.connectionActive || device.isConnectable == false)
                        }.padding(.vertical, 4)
                    }
                }
                if let selected = diagnostics.selectedDevice {
                    Section("Selected device snapshot") {
                        LabeledContent("Name", value: selected.name)
                        LabeledContent("Local name", value: selected.localName ?? "Not advertised")
                        Text(selected.id.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Inspection: \(diagnostics.inspectionCompleted ? "Complete snapshot" : "Incomplete or pending")")
                        Text("\(diagnostics.services.count) services discovered. GATT access alone does not establish chess compatibility.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(diagnostics.services.enumerated()), id: \.offset) { _, service in
                    Section("Service \(service.uuid)") {
                        Text(service.isPrimary ? "Primary service" : "Secondary service").font(.caption)
                        ForEach(Array(service.characteristics.enumerated()), id: \.offset) { _, characteristic in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(characteristic.uuid).font(.caption.monospaced()).textSelection(.enabled)
                                Text(characteristic.properties.isEmpty ? "No properties reported" : characteristic.properties.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section("Export inspection report") {
                    TextField("Board firmware (optional)", text: $firmware)
                    TextField("Test conditions: board screen, official app closed, etc.", text: $notes, axis: .vertical)
                    ShareLink(item: report) { Label("Export BLE report", systemImage: "square.and.arrow.up") }
                    Text("Includes the selected device's name, identifier, advertised services, discovered GATT metadata, and the last 200 diagnostic events. Other nearby device names are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(diagnostics.logs.suffix(12).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("BLE Diagnostics")
            .onDisappear { diagnostics.disconnect() }
            .alert("Inspection failed", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Close", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }
    private var visibleDevices: [BLEDiagnosticDevice] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        return diagnostics.devices.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    private func connectableText(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "Unknown"
    }
    private var report: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let selected = diagnostics.selectedDevice
        let gatt = diagnostics.services.map { service in
            let characteristics = service.characteristics.map { "  \($0.uuid) [\($0.properties.joined(separator: ", "))]" }.joined(separator: "\n")
            return "Service \(service.uuid) (\(service.isPrimary ? "primary" : "secondary"))\n\(characteristics)"
        }.joined(separator: "\n\n")
        return """
        ChessBoardConnect · ConnectTestApp \(version) (\(build))
        Mode: BLE metadata-only diagnostics (no characteristic values or board commands)
        Date: \(Date().formatted(.iso8601))
        Device: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Status: \(diagnostics.status)
        Inspection complete: \(diagnostics.inspectionCompleted)
        Devices discovered: \(diagnostics.devices.count)
        Selected name: \(selected?.name ?? "None")
        Selected identifier: \(selected?.id.uuidString ?? "None")
        Advertised local name: \(selected?.localName ?? "Not advertised")
        Advertised services: \(selected?.advertisedServices.joined(separator: ", ") ?? "None")
        Advertised connectable: \(connectableText(selected?.isConnectable))
        Selected RSSI: \(selected.map { $0.rssi == 127 ? "Unavailable" : "\($0.rssi) dBm" } ?? "Not recorded")
        Firmware (entered manually): \(firmware.isEmpty ? "Not provided" : firmware)
        Test conditions: \(notes.isEmpty ? "Not provided" : notes)

        GATT snapshot:
        \(gatt.isEmpty ? "No service metadata collected" : gatt)

        Events:
        \(diagnostics.logs.joined(separator: "\n"))
        """
    }
}
