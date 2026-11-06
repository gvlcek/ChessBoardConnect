import Foundation

/// Discovery instructions are separate from the capabilities of a connected board.
struct LabConfiguration: Hashable, Identifiable {
    enum Discovery: Hashable {
        case advertisements
        case systemConnected(namePrefix: String?)
    }

    let id: String
    let label: String
    let title: String
    let discovery: Discovery
    let searchTitle: String
    let instructions: String

    static let nearbyBoards = LabConfiguration(
        id: "nearby", label: "Board test", title: "Connect Test",
        discovery: .advertisements, searchTitle: "Scan",
        instructions: "Turn on the board and disconnect other apps. The first scan requests Bluetooth permission."
    )
    static let chessUp = LabConfiguration(
        id: "chessup", label: "ChessUp", title: "ChessUp Test",
        discovery: .systemConnected(namePrefix: "ChessUp"), searchTitle: "Find ChessUp",
        instructions: "Connect using the official ChessUp app, return here, and tap Find ChessUp. After connecting, send a full FEN below to start study mode."
    )
    static let presets = [nearbyBoards, chessUp]
}
