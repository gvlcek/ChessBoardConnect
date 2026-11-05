import Foundation
import CoreBluetooth
import Combine

@MainActor
final class BluetoothSession: NSObject, ObservableObject {
    @Published private(set) var devices: [BoardDevice] = []
    @Published private(set) var status = "Bluetooth not started" { didSet { log(status) } }
    @Published private(set) var ready = false
    @Published private(set) var scanning = false
    @Published private(set) var position: BoardPosition?
    @Published private(set) var lastMove: BoardMove?
    @Published private(set) var logs: [String] = []
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var capabilities: BoardCapabilities = []

    private let registry: DriverRegistry
    private var driver: (any BoardDriver)?
    private var profile: BluetoothProfile? { driver?.profile }
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var lastDevice: UUID?
    private var command: CBCharacteristic?
    private var notifications: [CBCharacteristic] = []
    private var queued: [PendingCommand] = []
    private var writing = false
    private var scanRequested = false
    private var watchdog: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeTimeout: Task<Void, Never>?

    override init() {
        registry = .standard
        super.init()
        // Lazily created after the user taps Search; this triggers the iOS permission.
    }
    private func log(_ text: String) {
        logs.append("\(Date().formatted(.iso8601))  \(text)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
    func clearLogs() { logs.removeAll(keepingCapacity: true) }
    func scan() {
        guard active == nil else { return }
        scanRequested = true
        devices = []; peripherals = [:]
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { startScan() }
    }
    private func startScan() {
        guard central.state == .poweredOn, scanRequested else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true; state = .scanning; status = "Scanning for compatible boards…"; log(status)
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            self.central.stopScan(); self.scanning = false; self.scanRequested = false
            self.state = .discovered
            self.status = self.devices.isEmpty ? "No boards found. Disconnect other apps and scan again." : "Select your board"
        }
    }
    func connect(_ id: UUID) throws {
        guard active == nil else { throw ConnectError.busy }
        guard central?.state == .poweredOn, let peripheral = peripherals[id],
              let name = devices.first(where: { $0.id == id })?.name,
              let selectedDriver = registry.makeDriver(for: name) else { throw ConnectError.deviceNotFound }
        driver = selectedDriver; capabilities = selectedDriver.capabilities; state = .connecting
        watchdog?.cancel(); scanRequested = false; scanning = false; central.stopScan()
        lastDevice = id; active = peripheral; peripheral.delegate = self
        status = "Connecting to \(peripheral.name ?? "Board")…"; log(status)
        central.connect(peripheral)
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail("Connection timed out. Try reconnecting.")
        }
    }
    func reconnect() throws {
        guard let lastDevice else { throw ConnectError.deviceNotFound }
        try connect(lastDevice)
    }
    func stopScan() {
        central?.stopScan(); scanRequested = false; scanning = false
        if active == nil { watchdog?.cancel(); state = .idle; status = "Scan stopped" }
    }
    var canReconnect: Bool { active == nil && lastDevice != nil }
    var connectedOrConnecting: Bool { active != nil }
    func disconnect() {
        stopScan()
        if let active { central.cancelPeripheralConnection(active) }
        reset(); state = .disconnected; status = "Disconnected"
    }
    private func fail(_ message: String) {
        central?.stopScan(); scanRequested = false; scanning = false
        if let active { central.cancelPeripheralConnection(active) }
        reset(); state = .failed(message); status = message
    }
    private func reset() {
        watchdog?.cancel(); writeTask?.cancel(); writeTimeout?.cancel()
        ready = false; active = nil; command = nil; notifications = []
        queued = []; writing = false; driver = nil; capabilities = []
        position = nil; lastMove = nil
    }
    func showLights(_ squares: [Int]) throws {
        guard ready, let driver else { throw ConnectError.notConnected }
        guard capabilities.contains(.controlLights) else { throw ConnectError.unsupportedCapability }
        guard squares.allSatisfy({ (0..<64).contains($0) }) else { throw ConnectError.invalidSquare }
        // Only light patterns replace pending light patterns, not other commands.
        queued.removeAll { $0.kind == .lights }
        enqueue(try driver.lightsCommand(squares), kind: .lights)
    }
    func refresh() throws {
        guard ready, let driver else { throw ConnectError.notConnected }
        guard capabilities.contains(.readPosition) else { throw ConnectError.unsupportedCapability }
        position = nil
        enqueue(try driver.refreshCommand()); waitForPosition()
    }
    func send(_ command: BoardCommand) throws {
        switch command {
        case .requestPosition: try refresh()
        case .setLights(let squares): try showLights(squares)
        case .sendMove(let move):
            guard ready, let driver else { throw ConnectError.notConnected }
            guard capabilities.contains(.sendMove) else { throw ConnectError.unsupportedCapability }
            enqueue(try driver.moveCommand(move))
        case .loadPosition(let fen):
            guard ready, let driver else { throw ConnectError.notConnected }
            guard capabilities.contains(.loadPosition) else { throw ConnectError.unsupportedCapability }
            enqueue(try driver.positionCommand(fen))
        }
    }
    private enum CommandKind { case lights, general }
    private struct PendingCommand { let data: Data; let kind: CommandKind }
    private func enqueue(_ bytes: Data, kind: CommandKind = .general) {
        guard ready else { return }
        queued.append(PendingCommand(data: bytes, kind: kind)); pump()
    }
    private func pump() {
        guard !writing, ready, let active, let command, !queued.isEmpty else { return }
        let type: CBCharacteristicWriteType = command.properties.contains(.write) ? .withResponse : .withoutResponse
        if type == .withoutResponse && !active.canSendWriteWithoutResponse { return }
        writing = true
        let bytes = queued.removeFirst().data
        log("TX " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        active.writeValue(bytes, for: command, type: type)
        if type == .withoutResponse { finishWrite() }
        else {
            writeTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.fail("The board did not acknowledge the command. Reconnect to continue.")
            }
        }
    }
    private func finishWrite() {
        writeTimeout?.cancel()
        // Same minimum pacing as the manufacturer's SDK, without blocking the UI.
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.writing = false; self.pump()
        }
    }
    private func checkReady() {
        guard !ready, let active, active.state == .connected,
              command != nil, !notifications.isEmpty, notifications.allSatisfy({ $0.isNotifying }) else { return }
        watchdog?.cancel(); ready = true; state = .connected
        status = "Connected · waiting for position"; log(status)
        driver?.initialCommands.forEach { enqueue($0) }; waitForPosition()
    }
    private func waitForPosition() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.position == nil else { return }
            self.status = "Connected, no position received. Move a piece or tap Request position."
            self.log(self.status)
        }
    }
}

// Core Bluetooth is configured with the main queue above. These conformances
// bridge its nonisolated Objective-C delegates to that main-actor execution.
extension BluetoothSession: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScan()
        case .unauthorized: fail("Allow Bluetooth in Settings → Privacy & Security → Bluetooth.")
        case .poweredOff: fail("Bluetooth is off. Turn it on and scan again.")
        case .unsupported: fail("This device does not support Bluetooth LE.")
        case .resetting: fail("Bluetooth is resetting. Scan again.")
        default: status = "Waiting for Bluetooth…"
        }
        if central.state != .poweredOn { scanning = false }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard let candidate = registry.makeDriver(for: name) else { return }
        peripherals[peripheral.identifier] = peripheral
        let device = BoardDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, capabilities: candidate.capabilities)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device); log("Found: \(name) · \(device.id)") }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral else { return }
        state = .discoveringServices; status = "Discovering services…"; log(status)
        peripheral.discoverServices(profile.map { $0.services.keys.map { CBUUID(string: $0) } })
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }; fail("Connection failed: \(error?.localizedDescription ?? "no details")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active === peripheral else { return }
        reset(); state = .disconnected; status = "Connection lost. Reconnect to receive a fresh position."; log(status)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active === peripheral else { return }
        if let error { fail(error.localizedDescription); return }
        guard let profile else { return }
        let services = peripheral.services ?? []
        guard profile.services.keys.allSatisfy({ id in services.contains { $0.uuid == CBUUID(string: id) } }) else {
            fail("The expected Bluetooth services are missing for this board."); return
        }
        for service in services {
            if let ids = profile.services[service.uuid.uuidString.lowercased()] {
                peripheral.discoverCharacteristics(ids.map { CBUUID(string: $0) }, for: service)
            }
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active === peripheral, let profile else { return }
        if let error { fail(error.localizedDescription); return }
        let found = service.characteristics ?? []
        for id in profile.services[service.uuid.uuidString.lowercased()] ?? [] {
            guard let characteristic = found.first(where: { $0.uuid == CBUUID(string: id) }) else {
                fail("A required Bluetooth characteristic is missing."); return
            }
            if characteristic.uuid == CBUUID(string: profile.writeID) {
                guard characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) else {
                    fail("The command characteristic does not support writes."); return
                }
                command = characteristic
            }
            if profile.notificationIDs.contains(id) {
                guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
                    fail("The data characteristic does not support notifications."); return
                }
                notifications.append(characteristic); peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        checkReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral else { return }
        if let error { fail(error.localizedDescription); return }
        checkReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, var receivingDriver = driver,
              profile?.notificationIDs.contains(characteristic.uuid.uuidString.lowercased()) == true else { return }
        if let error { position = nil; log("Receive error: \(error.localizedDescription)"); return }
        guard let bytes = characteristic.value else { return }
        log("RX " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        do {
            let events = try receivingDriver.receive(bytes, characteristic: characteristic.uuid.uuidString.lowercased())
            driver = receivingDriver
            for event in events {
                switch event {
                case .position(let decoded):
                    watchdog?.cancel(); state = .receivingPosition
                    status = "Connected · receiving positions"; position = decoded
                case .move(let move): lastMove = move
                case .write(let bytes): enqueue(bytes)
                }
            }
        } catch {
            driver = receivingDriver; position = nil
            log("Discarded data: \(error)")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral, characteristic.uuid == command?.uuid, writing else { return }
        if let error { fail("Send error: \(error.localizedDescription)"); return }
        finishWrite()
    }
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard active === peripheral else { return }; pump()
    }
}
