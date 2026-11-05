import SwiftUI
import ChessBoardConnect

/// This app consumes only the library's public interface, just like any host app.
struct ConnectionLabView: View {
    @StateObject private var connect = BoardConnect()
    @Environment(\.scenePhase) private var phase
    @State private var selectedName = "Sin seleccionar"
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
                    Text("Probá la conexión y los datos del tablero sin abrir Chess Dex.")
                        .font(.callout).foregroundStyle(.secondary)
                    Label(connect.status, systemImage: connect.ready ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
                    LabeledContent("Estado", value: stateName)
                    LabeledContent("Tablero seleccionado", value: selectedName)
                    HStack {
                        Button("Buscar") { connect.scan() }
                            .disabled(connect.scanning || connect.connectedOrConnecting)
                        if connect.scanning { Button("Detener") { connect.stopScan() } }
                        if connect.connectedOrConnecting {
                            Button("Desconectar") { connect.disconnect() }
                        } else if connect.canReconnect {
                            Button("Reconectar") { perform { try connect.reconnect() } }
                        }
                    }.buttonStyle(.bordered)
                    Text("Encendé el tablero y desconectalo de otras apps. La búsqueda pide permiso Bluetooth la primera vez.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Conexión") }

                if !connect.connectedOrConnecting {
                    Section("Tableros encontrados · \(connect.devices.count)") {
                        if connect.devices.isEmpty {
                            Text(connect.scanning ? "Buscando dispositivos compatibles…" : "Iniciá una búsqueda para elegir tu tablero.")
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

                Section("Capacidades del tablero conectado") {
                    capability("Lectura de posiciones", .readPosition)
                    capability("Control de luces", .controlLights)
                    capability("Envío de jugadas", .sendMove)
                    capability("Carga de posiciones", .loadPosition)
                    Text("Las capacidades son declaradas por el driver. Hay que verificarlas físicamente.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Posición recibida · blancas abajo") {
                    if let position = connect.position {
                        boardGrid(position)
                        Text(position.fen).font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text("Sin lectura vigente").foregroundStyle(.secondary)
                    }
                    LabeledContent("Lecturas de esta sesión", value: "\(readingCount)")
                    if let lastReading {
                        LabeledContent("Última lectura", value: lastReading.formatted(date: .omitted, time: .standard))
                    }
                    Button("Solicitar posición") { perform { try connect.refresh() } }
                        .disabled(!supports(.readPosition))
                    Text("La posición de arriba viene del tablero. No es una partida simulada ni una posición objetivo.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Luces") {
                    TextField("Casillas, por ejemplo e2 e4", text: $lightSquares)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button("Encender") {
                            perform {
                                let names = lightSquares.lowercased().split { $0.isWhitespace || $0 == "," }
                                let indices = names.compactMap { BoardPosition.index(String($0)) }
                                guard !names.isEmpty, indices.count == names.count else { throw LabError.invalidSquares }
                                try connect.showLights(indices)
                            }
                        }
                        Button("Apagar todas") { perform { try connect.showLights([]) } }
                    }.buttonStyle(.bordered).disabled(!supports(.controlLights))
                    Text("Confirmá mirando el tablero que se iluminan las casillas indicadas.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if supports(.sendMove) {
                    Section("Enviar jugada") {
                        TextField("Origen", text: $moveFrom).textInputAutocapitalization(.never).autocorrectionDisabled()
                        TextField("Destino", text: $moveTo).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Enviar") {
                            perform {
                                guard let from = BoardPosition.index(moveFrom.lowercased()), let to = BoardPosition.index(moveTo.lowercased()) else { throw LabError.invalidSquares }
                                try connect.send(.sendMove(BoardMove(from: from, to: to)))
                            }
                        }
                    }
                }
                if supports(.loadPosition) {
                    Section("Cargar posición") {
                        TextField("FEN completo", text: $fen, axis: .vertical)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Enviar posición") { perform { try connect.send(.loadPosition(fen)) } }
                    }
                }
                if let move = connect.lastMove {
                    Section("Última jugada reportada") {
                        Text("\(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))")
                    }
                }
                if !commandResult.isEmpty {
                    Section { Text(commandResult).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Diagnóstico") {
                    TextField("Firmware del tablero (opcional)", text: $firmware)
                    ShareLink(item: diagnosticReport) {
                        Label("Exportar registro", systemImage: "square.and.arrow.up")
                    }
                    Text("Se exportan los últimos 200 eventos, incluidos mensajes TX/RX, y los datos del dispositivo que figuran en el informe.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(connect.logs.suffix(20).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Connect Test")
            .alert("No se pudo completar", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("Cerrar", role: .cancel) { errorMessage = nil }
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
        LabeledContent(title, value: !connect.ready ? "Sin conexión" : supports(capability) ? "Disponible" : "No disponible")
    }
    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            commandResult = "Acción solicitada. En los comandos, encolado no equivale a ejecución física: verificá el tablero y la respuesta."
        } catch {
            commandResult = "La acción falló."
            errorMessage = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }
    private var stateName: String {
        switch connect.state {
        case .idle: "En espera"
        case .scanning: "Buscando"
        case .discovered: "Búsqueda completada"
        case .connecting: "Conectando"
        case .discoveringServices: "Preparando comunicación"
        case .connected: "Conectado"
        case .receivingPosition: "Recibiendo posiciones"
        case .disconnected: "Desconectado"
        case .failed(let message): "Error: \(message)"
        }
    }
    private var diagnosticReport: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return """
        ChessBoardConnect · ConnectTestApp \(version) (\(build))
        Fecha: \(Date().formatted(.iso8601))
        Dispositivo: \(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        Tablero seleccionado: \(selectedName)
        Firmware (informado manualmente): \(firmware.isEmpty ? "No informado" : firmware)
        Estado: \(stateName)
        Capacidades: \(connect.capabilities.rawValue)
        Posición vigente: \(connect.position?.fen ?? "Sin lectura")
        Lecturas: \(readingCount)

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
    var errorDescription: String? { "Ingresá casillas entre a1 y h8, separadas por espacios o comas. Por ejemplo: e2 e4." }
}
