import Foundation
import Combine

public enum BLEDiscoverySource: String, Equatable, Sendable {
    case advertisement = "BLE advertisement"
    case systemConnection = "iOS/macOS connected peripheral"
}

public struct BLEDiagnosticDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let localName: String?
    public let advertisedServices: [String]
    public let rssi: Int
    public let isConnectable: Bool?
    public let source: BLEDiscoverySource

    public init(id: UUID, name: String, localName: String?, advertisedServices: [String], rssi: Int, isConnectable: Bool?, source: BLEDiscoverySource = .advertisement) {
        self.id = id; self.name = name; self.localName = localName
        self.advertisedServices = advertisedServices; self.rssi = rssi; self.isConnectable = isConnectable
        self.source = source
    }
}

public struct BLEDiagnosticCharacteristic: Equatable, Sendable {
    public let uuid: String
    public let properties: [String]
    public init(uuid: String, properties: [String]) { self.uuid = uuid; self.properties = properties }
}

public struct BLEDiagnosticService: Equatable, Sendable {
    public let uuid: String
    public let isPrimary: Bool
    public let characteristics: [BLEDiagnosticCharacteristic]
    public init(uuid: String, isPrimary: Bool, characteristics: [BLEDiagnosticCharacteristic]) {
        self.uuid = uuid; self.isPrimary = isPrimary; self.characteristics = characteristics
    }
}

public enum BLEDiagnosticState: Equatable, Sendable {
    case idle, waitingForBluetooth, scanning, scanComplete, connecting, discoveringServices, inspected, disconnected
    case failed(String)

    public var isScanning: Bool { self == .waitingForBluetooth || self == .scanning }
    public var connectionActive: Bool { self == .connecting || self == .discoveringServices || self == .inspected }
}

public enum BLEDiagnosticError: LocalizedError, Equatable, Sendable {
    case busy, unknownDevice, notConnectable
    public var errorDescription: String? {
        switch self {
        case .busy: "Disconnect the current inspection before selecting another device."
        case .unknownDevice: "Device not found. Scan again before inspecting it."
        case .notConnectable: "This device advertises itself as non-connectable."
        }
    }
}

/// Driver-independent BLE discovery and GATT metadata inspection.
/// No characteristic reads, writes, subscriptions, or board commands are exposed.
@MainActor
public final class BoardDiagnostics: ObservableObject {
    @Published public private(set) var devices: [BLEDiagnosticDevice] = []
    @Published public private(set) var state: BLEDiagnosticState = .idle
    @Published public private(set) var status = "BLE diagnostics not started"
    @Published public private(set) var selectedDevice: BLEDiagnosticDevice?
    @Published public private(set) var services: [BLEDiagnosticService] = []
    @Published public private(set) var inspectionCompleted = false
    @Published public private(set) var logs: [String] = []
    private let transport: any BLEInspectionTransport
    private let namePrefix: String?

    /// Optionally limits discovery results to a case-insensitive peripheral/local name prefix.
    /// Omit the prefix to include all candidates, including unnamed peripherals.
    public convenience init(namePrefix: String? = nil) {
        self.init(transport: CoreBluetoothInspectionTransport(), namePrefix: namePrefix)
    }
    init(transport: any BLEInspectionTransport, namePrefix: String? = nil) {
        self.transport = transport
        self.namePrefix = namePrefix?.lowercased()
        transport.onEvent = { [weak self] event in self?.receive(event) }
    }

    public func scan() {
        guard !state.connectionActive, !state.isScanning else { return }
        devices = []; selectedDevice = nil; services = []; inspectionCompleted = false; logs = []
        transport.scan()
    }
    public func stopScan() { transport.stopScan() }
    /// Looks up already-connected UART candidates, including connections owned by other apps.
    /// This is not an advertisement scan or evidence that a candidate is a ChessUp.
    public func checkConnectedDevices() {
        guard !state.connectionActive, !state.isScanning else { return }
        devices = []; selectedDevice = nil; services = []; inspectionCompleted = false; logs = []
        transport.checkConnectedDevices()
    }
    /// Select a discovered device snapshot for export without opening a connection.
    public func selectForReport(_ id: UUID) throws {
        guard !state.connectionActive else { throw BLEDiagnosticError.busy }
        guard let device = devices.first(where: { $0.id == id }) else { throw BLEDiagnosticError.unknownDevice }
        selectedDevice = device; services = []; inspectionCompleted = false
        log("Selected device: \(device.name) · \(device.id)")
    }
    public func inspect(_ id: UUID) throws {
        try selectForReport(id)
        guard selectedDevice?.isConnectable != false else { throw BLEDiagnosticError.notConnectable }
        transport.inspect(id)
    }
    /// Collected metadata remains available for export after disconnection.
    public func disconnect() { transport.disconnect() }
    /// Clears events only; selected devices and collected metadata remain available.
    public func clearLogs() { logs.removeAll(keepingCapacity: true) }

    private func receive(_ event: BLEInspectionEvent) {
        switch event {
        case .device(let device):
            if let namePrefix {
                guard device.name.lowercased().hasPrefix(namePrefix)
                    || device.localName?.lowercased().hasPrefix(namePrefix) == true else { return }
            }
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
            else { devices.append(device) }
        case .state(let next, let description):
            state = next; status = description; log(description)
            if case .failed = next { inspectionCompleted = false }
        case .services(let snapshot, let complete):
            services = snapshot; inspectionCompleted = complete
        }
    }
    private func log(_ message: String) {
        logs.append("\(Date().formatted(.iso8601))  \(message)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
}

@MainActor
protocol BLEInspectionTransport: AnyObject {
    var onEvent: ((BLEInspectionEvent) -> Void)? { get set }
    func scan()
    func stopScan()
    func checkConnectedDevices()
    func inspect(_ id: UUID)
    func disconnect()
}

enum BLEInspectionEvent {
    case device(BLEDiagnosticDevice)
    case state(BLEDiagnosticState, String)
    case services([BLEDiagnosticService], complete: Bool)
}
