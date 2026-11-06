import SwiftUI

struct ReportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension ReportMetadata {
    /// UIKit metadata is captured once on MainActor; the exporter uses plain values.
    @MainActor
    static var current: Self {
        Self(
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
            device: "\(UIDevice.current.model), \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        )
    }
}
