import Foundation
import CoreBluetooth
import Combine

@MainActor
final class BluetoothSession: NSObject, ObservableObject {
    @Published private(set) var devices: [BoardDevice] = []
    @Published private(set) var status = "Bluetooth not started" { didSet { if status != oldValue { log(status) } } }
    @Published private(set) var ready = false
    @Published private(set) var scanning = false
    @Published private(set) var canReconnect = false
    @Published private(set) var position: BoardPosition?
    @Published private(set) var lastMove: BoardMove?
    @Published private(set) var logs: [String] = []
    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var capabilities: BoardCapabilities = []

    private let registry: DriverRegistry
    private var driver: (any BoardDriver)?
    private var profile: BluetoothProfile? { driver?.profile }
    private var central: CBCentralManager?
    private var peers = PeripheralRegistry<CBPeripheral>()
    private var active: CBPeripheral? {
        get { peers.active }
        set { peers.active = newValue }
    }
    private var lastDevice: UUID?
    private var command: CBCharacteristic?
    private var notifications: [CBCharacteristic] = []
    private var queued: [PendingCommand] = []
    private var writing = false
    private var scanRequested = false
    private var connectedLookupRequested = false
    private var lookupNamePrefix: String?
    private var replyTimeout: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var writeTask: Task<Void, Never>?
    private var writeTimeout: Task<Void, Never>?

    override init() {
        registry = .standard
        super.init()
        // Lazily created after the user taps Search; this triggers the iOS permission.
    }
    /// The manager state is authoritative: do not wait for per-device callbacks
    /// or issue cancel/stop commands while Bluetooth is unavailable.
    func handleBluetoothState(_ bluetoothState: CBManagerState) {
        if bluetoothState == .poweredOn {
            if connectedLookupRequested { lookupConnectedBoards() } else { startScan() }
            return
        }
        if bluetoothState == .unknown, !peers.hasReferences {
            status = "Waiting for Bluetooth…"
            return
        }
        active?.delegate = nil
        peers.invalidate()
        scanRequested = false; connectedLookupRequested = false; scanning = false
        devices = []
        reset()
        let message: String
        switch bluetoothState {
        case .unauthorized: message = "Allow Bluetooth in Settings → Privacy & Security → Bluetooth."
        case .poweredOff: message = "Bluetooth is off. Turn it on and scan again."
        case .unsupported: message = "This device does not support Bluetooth LE."
        case .resetting: message = "Bluetooth is resetting. Scan again."
        default: message = "Bluetooth is unavailable. Scan again when it is ready."
        }
        state = .failed(message); status = message
    }
    private func log(_ text: String) {
        logs.append("\(Date().formatted(.iso8601))  \(text)")
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
    }
    func clearLogs() { logs.removeAll(keepingCapacity: true) }
    func scan() {
        guard active == nil else { return }
        scanRequested = true; connectedLookupRequested = false
        devices = []; peers.discovered = [:]; updateReconnectAvailability()
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { startScan() }
    }
    func findConnectedBoards(namePrefix: String?) {
        guard active == nil, !scanning else { return }
        connectedLookupRequested = true; scanRequested = false; lookupNamePrefix = namePrefix?.lowercased()
        devices = []; peers.discovered = [:]; updateReconnectAvailability()
        if central == nil { central = CBCentralManager(delegate: self, queue: .main) }
        else { lookupConnectedBoards() }
    }
    private func lookupConnectedBoards() {
        guard connectedLookupRequested, let central, central.state == .poweredOn else { return }
        connectedLookupRequested = false
        let services = Set(registry.registrations.flatMap { $0.make().profile.services.keys })
        let found = central.retrieveConnectedPeripherals(withServices: services.map { CBUUID(string: $0) })
        for peripheral in found {
            let name = peripheral.name ?? ""
            guard lookupNamePrefix.map({ name.lowercased().hasPrefix($0) }) ?? true,
                  let driver = registry.makeDriver(for: name) else { continue }
            peers.discovered[peripheral.identifier] = peripheral
            devices.append(BoardDevice(id: peripheral.identifier, name: name, rssi: 127, capabilities: driver.capabilities))
        }
        updateReconnectAvailability()
        state = .discovered
        status = devices.isEmpty ? "No connected boards found. Connect in the official app and try again." : "Select your board"
    }
    private func startScan() {
        guard let central, central.state == .poweredOn, scanRequested else { return }
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        scanning = true; state = .scanning; status = "Scanning for compatible boards…"
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self else { return }
            if self.central?.state == .poweredOn { self.central?.stopScan() }
            self.scanning = false; self.scanRequested = false
            self.state = .discovered
            self.status = self.devices.isEmpty ? "No boards found. Disconnect other apps and scan again." : "Select your board"
        }
    }
    func connect(_ id: UUID) throws {
        guard active == nil, !peers.isRetiring(id) else { throw ConnectError.busy }
        guard let central, central.state == .poweredOn, let peripheral = peers.discovered[id],
              let name = devices.first(where: { $0.id == id })?.name,
              let selectedDriver = registry.makeDriver(for: name) else { throw ConnectError.deviceNotFound }
        driver = selectedDriver; capabilities = selectedDriver.capabilities; state = .connecting
        watchdog?.cancel(); scanRequested = false; scanning = false; central.stopScan()
        lastDevice = id; active = peripheral; peripheral.delegate = self
        updateReconnectAvailability()
        status = "Connecting to \(peripheral.name ?? "Board")…"
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
        if central?.state == .poweredOn { central?.stopScan() }
        scanRequested = false; connectedLookupRequested = false; scanning = false
        if active == nil { watchdog?.cancel(); state = .idle; status = "Scan stopped" }
    }
    private func updateReconnectAvailability() {
        guard active == nil, central?.state == .poweredOn, let lastDevice else {
            canReconnect = false
            return
        }
        canReconnect = !peers.isRetiring(lastDevice) && peers.discovered[lastDevice] != nil
            && devices.contains(where: { $0.id == lastDevice })
    }
    var connectedOrConnecting: Bool { active != nil }
    func disconnect() {
        stopScan()
        cancelActiveConnection()
        reset(); state = .disconnected; status = "Disconnected"
    }
    private func fail(_ message: String) {
        if central?.state == .poweredOn { central?.stopScan() }
        scanRequested = false; connectedLookupRequested = false; scanning = false
        cancelActiveConnection()
        reset(); state = .failed(message); status = message
    }
    private func cancelActiveConnection() {
        guard let active else { return }
        active.delegate = nil
        peers.beginCancellation(active, id: active.identifier)
        if central?.state == .poweredOn { central?.cancelPeripheralConnection(active) }
    }
    private func reset() {
        watchdog?.cancel(); writeTask?.cancel(); writeTimeout?.cancel(); replyTimeout?.cancel()
        ready = false; active = nil; command = nil; notifications = []
        queued = []; writing = false; driver = nil; capabilities = []
        position = nil; lastMove = nil
        updateReconnectAvailability()
    }
    func showLights(_ squares: [Int]) throws {
        guard ready else { throw ConnectError.notConnected }
        guard capabilities.contains(.controlLights) else { throw ConnectError.unsupportedCapability }
        guard squares.allSatisfy({ (0..<64).contains($0) }) else { throw ConnectError.invalidSquare }
        try prepare(.setLights(squares), kind: .lights)
    }
    func refresh() throws {
        guard ready else { throw ConnectError.notConnected }
        guard capabilities.contains(.readPosition) else { throw ConnectError.unsupportedCapability }
        try prepare(.requestPosition, kind: .refresh)
        waitForPosition()
    }
    func send(_ command: BoardCommand) throws {
        switch command {
        case .requestPosition: try refresh()
        case .setLights(let squares): try showLights(squares)
        case .sendMove(let move):
            guard ready else { throw ConnectError.notConnected }
            guard capabilities.contains(.sendMove) else { throw ConnectError.unsupportedCapability }
            try prepare(.sendMove(move))
        case .loadPosition(let fen):
            guard ready else { throw ConnectError.notConnected }
            guard capabilities.contains(.loadPosition) else { throw ConnectError.unsupportedCapability }
            try prepare(.loadPosition(fen))
        }
    }
    private func prepare(_ command: BoardCommand, kind: CommandKind = .general) throws {
        guard ready, let driver, let active, let characteristic = self.command else { throw ConnectError.notConnected }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        let prepared = try DriverCommands.prepare(command, driver: driver, maximumLength: active.maximumWriteValueLength(for: type))
        self.driver = prepared.driver
        if case .loadPosition = command { lastMove = nil }
        if case .requestPosition = command { position = nil }
        // Replace queued patterns/refreshes only after preparation succeeds.
        if kind != .general { queued.removeAll { $0.kind == kind } }
        prepared.packets.forEach { enqueue($0, kind: kind) }
        updateReplyTimeout()
    }
    private func updateReplyTimeout() {
        replyTimeout?.cancel()
        guard driver?.commandPending == true else { return }
        replyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.fail("The board did not confirm the protocol command. Reconnect and load a position before retrying.")
        }
    }
    private enum CommandKind { case lights, refresh, general }
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
        guard bytes.count <= active.maximumWriteValueLength(for: type) else {
            fail("Command exceeds this connection's write limit. Export the log and reconnect."); return
        }
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
              command != nil, let profile, notifications.count == profile.notificationIDs.count,
              !notifications.isEmpty, notifications.allSatisfy({ $0.isNotifying }) else { return }
        watchdog?.cancel(); ready = true; state = .connected
        status = capabilities.contains(.readPosition) ? "Connected · waiting for position" : "Connected · load a full FEN to start a study session"
        driver?.initialCommands.forEach { enqueue($0) }
        if capabilities.contains(.readPosition) { waitForPosition() }
    }
    private func waitForPosition() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.position == nil else { return }
            self.status = "Connected, no position received. Move a piece or tap Request position."
        }
    }
}

// Core Bluetooth is configured with the main queue above. These conformances
// bridge its nonisolated Objective-C delegates to that main-actor execution.
extension BluetoothSession: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        handleBluetoothState(central.state)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanRequested else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? ""
        guard let candidate = registry.makeDriver(for: name) else { return }
        peers.discovered[peripheral.identifier] = peripheral
        let device = BoardDevice(id: peripheral.identifier, name: name, rssi: RSSI.intValue, capabilities: candidate.capabilities)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device); log("Found: \(name) · \(device.id)") }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral else { return }
        state = .discoveringServices; status = "Discovering services…"
        peripheral.discoverServices(profile.map { $0.services.keys.map { CBUUID(string: $0) } })
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peers.finishCancellation(peripheral, id: peripheral.identifier) { updateReconnectAvailability(); return }
        guard active === peripheral else { return }
        peripheral.delegate = nil
        reset(); state = .failed("Connection failed")
        status = "Connection failed: \(error?.localizedDescription ?? "no details")"
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peers.finishCancellation(peripheral, id: peripheral.identifier) { updateReconnectAvailability(); return }
        guard active === peripheral else { return }
        peripheral.delegate = nil
        reset(); state = .disconnected; status = "Connection lost. Reconnect to receive a fresh position."
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
                if !notifications.contains(where: { $0.uuid == characteristic.uuid }) { notifications.append(characteristic) }
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        checkReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active === peripheral else { return }
        if let error { fail(error.localizedDescription); return }
        if ready, !characteristic.isNotifying {
            fail("Board notifications stopped. Reconnect before sending commands."); return
        }
        checkReady()
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard active === peripheral else { return }
        fail("Board services changed. Reconnect to rediscover the connection.")
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard ready, active === peripheral, var receivingDriver = driver,
              profile?.notificationIDs.contains(characteristic.uuid.uuidString.lowercased()) == true else { return }
        if let error { position = nil; log("Receive error: \(error.localizedDescription)"); return }
        guard let bytes = characteristic.value else { return }
        log("RX " + bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
        do {
            let events = try receivingDriver.receive(bytes, characteristic: characteristic.uuid.uuidString.lowercased())
            let wasPending = driver?.commandPending == true
            driver = receivingDriver
            for event in events {
                switch event {
                case .position(let decoded):
                    watchdog?.cancel()
                    if state != .receivingPosition { state = .receivingPosition }
                    if status != "Connected · receiving positions" { status = "Connected · receiving positions" }
                    position = decoded
                case .invalidData(let description):
                    position = nil
                    log("Discarded data: \(description)")
                case .move(let move):
                    lastMove = move
                    log("Board move: \(BoardPosition.name(move.from)) → \(BoardPosition.name(move.to))\(move.promotion.map(String.init) ?? "")")
                case .write(let bytes): enqueue(bytes)
                case .status(let message): status = message
                }
            }
            if wasPending && !receivingDriver.commandPending { replyTimeout?.cancel() }
            else if events.contains(where: { if case .status = $0 { true } else { false } }) && receivingDriver.commandPending { updateReplyTimeout() }
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
