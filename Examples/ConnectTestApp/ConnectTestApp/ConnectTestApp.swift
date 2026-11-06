import SwiftUI

@main
struct ConnectTestApp: App {
    var body: some Scene { WindowGroup { LabRootView() } }
}

private struct LabRootView: View {
    @State private var configuration = LabConfiguration.nearbyBoards

    var body: some View {
        VStack(spacing: 0) {
            Picker("Test mode", selection: $configuration) {
                ForEach(LabConfiguration.presets) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 16)
            ConnectionLabView(configuration: configuration)
                // A different discovery configuration owns a fresh model and session.
                .id(configuration.id)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}
