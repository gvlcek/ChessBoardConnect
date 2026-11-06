import Foundation

/// Extend the internal registry to add a board without changing a consumer app.
/// Each connection receives a fresh driver and its own protocol state.
struct DriverRegistration: Sendable {
    let matches: @Sendable (String) -> Bool
    let make: @Sendable () -> any BoardDriver
}
struct BluetoothProfile {
    let services: [String: [String]]
    let notificationIDs: Set<String>
    let writeID: String
}
enum DriverEvent {
    case position(BoardPosition)
    case move(BoardMove)
    case invalidData(String)
    case commandConfirmed
    case write(Data)
    case status(String)
}
protocol BoardDriver {
    var commandPending: Bool { get }
    mutating func prepare(_ command: BoardCommand) throws -> [Data]
    var capabilities: BoardCapabilities { get }
    var profile: BluetoothProfile { get }
    var initialCommands: [Data] { get }
    func moveCommand(_ move: BoardMove) throws -> Data
    func positionCommand(_ fen: String) throws -> Data
    func refreshCommand() throws -> Data
    func lightsCommand(_ squares: [Int]) throws -> Data
    mutating func receive(_ data: Data, characteristic: String) throws -> [DriverEvent]
}
struct DriverRegistry: Sendable {
    let registrations: [DriverRegistration]
    static let standard = Self(registrations: [
        DriverRegistration(matches: {
            let name = $0.lowercased()
            // Do not attach the classic protocol to Chessnut Move or Evo.
            return name.contains("chessnut") && !name.contains("move") && !name.contains("evo")
        }, make: { ChessnutDriver() }),
        DriverRegistration(matches: { $0.lowercased().hasPrefix("chessup") }, make: { ChessUpDriver() })
    ])
    func makeDriver(for name: String) -> (any BoardDriver)? {
        registrations.first(where: { $0.matches(name) })?.make()
    }
}

extension BoardDriver {
    var commandPending: Bool { false }
    mutating func prepare(_ command: BoardCommand) throws -> [Data] {
        switch command {
        case .sendMove(let move): return [try moveCommand(move)]
        case .loadPosition(let fen): return [try positionCommand(fen)]
        case .requestPosition: return [try refreshCommand()]
        case .setLights(let squares): return [try lightsCommand(squares)]
        }
    }
    func moveCommand(_ move: BoardMove) throws -> Data { throw ConnectError.unsupportedCapability }
    func positionCommand(_ fen: String) throws -> Data { throw ConnectError.unsupportedCapability }
}

/// Stage a value-type driver's entire command batch before transport sends any packet.
enum DriverCommands {
    static func prepare(_ command: BoardCommand, driver: any BoardDriver, maximumLength: Int) throws -> (driver: any BoardDriver, packets: [Data]) {
        var staged = driver
        let packets = try staged.prepare(command)
        guard packets.allSatisfy({ $0.count <= maximumLength }) else { throw ConnectError.commandTooLarge }
        return (staged, packets)
    }
}
