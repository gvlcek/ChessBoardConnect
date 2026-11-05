import Foundation

struct ReportSnapshot: Sendable {
    let fields: [String]
    let logs: [String]
}

/// Pure Foundation so the real exporter is exercised by package tests on macOS.
enum ReportExport {
    static func prepare(_ snapshot: ReportSnapshot, directory: URL = FileManager.default.temporaryDirectory) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let folder = directory.appendingPathComponent("ChessBoardConnect-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("board-report.txt")
            do {
                let text = snapshot.fields.joined(separator: "\n") + "\n\n" + snapshot.logs.suffix(200).joined(separator: "\n")
                try text.write(to: file, atomically: true, encoding: .utf8)
                return file
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }.value
    }
    static func remove(_ file: URL) async {
        await Task.detached(priority: .utility) {
            // Remove only the app-owned report directory, never arbitrary caller paths.
            let folder = file.deletingLastPathComponent()
            guard file.lastPathComponent == "board-report.txt", folder.lastPathComponent.hasPrefix("ChessBoardConnect-") else { return }
            try? FileManager.default.removeItem(at: folder)
        }.value
    }
}
