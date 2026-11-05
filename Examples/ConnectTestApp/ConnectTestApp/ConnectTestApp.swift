import SwiftUI

@main
struct ConnectTestApp: App {
    var body: some Scene { WindowGroup { LabRootView() } }
}

private struct LabRootView: View {
    @State private var mode = LabMode.board
    var body: some View {
        VStack(spacing: 0) {
            Picker("Test mode", selection: $mode) {
                Text("Board test").tag(LabMode.board)
                Text("BLE diagnostics").tag(LabMode.ble)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal).padding(.top, 8)
            // Conditional views release the previous session when changing modes.
            if mode == .board { ConnectionLabView() }
            else { BLEDiagnosticLabView() }
        }
    }
}
private enum LabMode: Hashable { case board, ble }
