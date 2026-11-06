import Foundation

struct ChessnutDriver: BoardDriver {
    let capabilities: BoardCapabilities = [.readPosition, .controlLights]
    let profile = BluetoothProfile(
        services: [
            "1b7e8261-2877-41c3-b46e-cf057c562023": ["1b7e8262-2877-41c3-b46e-cf057c562023"],
            "1b7e8271-2877-41c3-b46e-cf057c562023": ["1b7e8272-2877-41c3-b46e-cf057c562023"]
        ],
        notificationIDs: ["1b7e8262-2877-41c3-b46e-cf057c562023"],
        writeID: "1b7e8272-2877-41c3-b46e-cf057c562023"
    )
    let initialCommands = [ChessnutCodec.realtime]
    private var frames = ChessnutFrames()
    func refreshCommand() throws -> Data { ChessnutCodec.realtime }
    func lightsCommand(_ squares: [Int]) throws -> Data { ChessnutCodec.leds(squares) }
    mutating func receive(_ data: Data, characteristic: String) throws -> [DriverEvent] {
        guard profile.notificationIDs.contains(characteristic.lowercased()) else { return [] }
        return frames.append(data).map { frame in
            do { return .position(try ChessnutCodec.decode(frame)) }
            catch { return .invalidData(String(describing: error)) }
        }
    }
}
