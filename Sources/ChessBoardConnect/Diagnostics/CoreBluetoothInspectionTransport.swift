import Foundation
import CoreBluetooth

/// Metadata-only transport. Never reads/writes values or enables notifications.
@MainActor
final class CoreBluetoothInspectionTransport: NSObject, BLEInspectionTransport {
    var onEvent: ((BLEInspectionEvent) -> Void)?
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var cancelling: Set<UUID> = []
    private var scanRequested = false
    private var watchdog: Task<Void, Never>?
    private var pendingServices: Set<ObjectIdentifier> = []

    func scan() {
        guard active == nil else { return }
        scanRequested = true; peripherals = [:]
        if central == nil {
            emit(.waitingForBluetooth, "Waiting for Bluetooth permission and availability…")
            central = CBCentralManager(delegate: self, queue: .main)
        } else { startScan() }
    }
    private func startScan() {
        guard scanRequested, let central else { return }
        guard central.state == .poweredOn else {
            if central.state == .unknown { emit(.waitingForBluetooth, "Waiting for Bluetooth…") }
            else { bluetoothUnavailable(central.state) }
            return
        }
        // No service/name/driver filter: ChessUp and unnamed peripherals remain visible.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        emit(.scanning, "Scanning all nearby BLE advertisements for 15 seconds…")
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self else { return }
            self.stopScan()
        }
    }
    func stopScan() {
        guard scanRequested else { return }
        central?.stopScan(); scanRequested = false; watchdog?.cancel()
        emit(.scanComplete, "Scan stopped. Select a device to inspect its GATT metadata.")
    }
    func inspect(_ id: UUID) {
        guard active == nil, !cancelling.contains(id) else {
            emit(.failed("Device busy"), "The previous connection is still closing. Try again shortly."); return
        }
        guard central?.state == .poweredOn, let peripheral = peripherals[id] else {
            emit(.failed("Device unavailable"), "Device unavailable. Check Bluetooth and scan again."); return
        }
        stopScan()
        active = peripheral; peripheral.delegate = self
        emit(.connecting, "Connecting for GATT inspection only…")
        central?.connect(peripheral)
        armTimeout("Connection timed out. Close the official app, restart the board, and scan again.")
    }
    func disconnect() {
        central?.stopScan(); scanRequested = false
        release(cancel: true)
        emit(.disconnected, "Disconnected. Collected metadata is retained for export.")
    }
    private func release(cancel: Bool) {
        watchdog?.cancel(); pendingServices = []
        if let active {
            active.delegate = nil
            if cancel {
                cancelling.insert(active.identifier)
                central?.cancelPeripheralConnection(active)
            }
        }
        active = nil
    }
    private func fail(_ message: String) {
        central?.stopScan(); scanRequested = false
        release(cancel: true)
        emit(.failed(message), message)
    }
    private func emit(_ state: BLEDiagnosticState, _ message: String) { onEvent?(.state(state, message)) }
    private func armTimeout(_ message: String) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.fail(message)
        }
    }
    private func bluetoothUnavailable(_ state: CBManagerState) {
        central?.stopScan(); scanRequested = false; release(cancel: false); cancelling = []
        let message: String
        switch state {
        case .unauthorized: message = "Allow Bluetooth in Settings → Privacy & Security → Bluetooth."
        case .poweredOff: message = "Bluetooth is off. Turn it on and scan again."
        case .unsupported: message = "This device does not support Bluetooth LE."
        case .resetting: message = "Bluetooth is resetting. Scan again when it is available."
        default: message = "Bluetooth is unavailable. Scan again."
        }
        emit(.failed(message), message)
    }
    private func publishServices(_ peripheral: CBPeripheral) {
        let snapshot = (peripheral.services ?? []).map { service in
            BLEDiagnosticService(uuid: service.uuid.uuidString.lowercased(), isPrimary: service.isPrimary,
                characteristics: (service.characteristics ?? []).map { characteristic in
                    BLEDiagnosticCharacteristic(uuid: characteristic.uuid.uuidString.lowercased(), properties: Self.properties(characteristic.properties))
                })
        }
        let complete = pendingServices.isEmpty
        onEvent?(.services(snapshot, complete: complete))
        if complete {
            watchdog?.cancel()
            emit(.inspected, "GATT inspection complete. No board commands or characteristic values were exchanged.")
        }
    }
    private static func properties(_ properties: CBCharacteristicProperties) -> [String] {
        let options: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeWithoutResponse"),
            (.notify, "notify"), (.indicate, "indicate"), (.broadcast, "broadcast"),
            (.authenticatedSignedWrites, "authenticatedSignedWrites"), (.extendedProperties, "extendedProperties"),
            (.notifyEncryptionRequired, "notifyEncryptionRequired"), (.indicateEncryptionRequired, "indicateEncryptionRequired")
        ]
        return options.compactMap { properties.contains($0.0) ? $0.1 : nil }
    }
}

// This central manager and all peripheral callbacks use the main queue.
extension CoreBluetoothInspectionTransport: @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { startScan() }
        else if central.state != .unknown { bluetoothUnavailable(central.state) }
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanRequested else { return }
        peripherals[peripheral.identifier] = peripheral
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        let device = BLEDiagnosticDevice(id: peripheral.identifier, name: localName ?? peripheral.name ?? "Unnamed device",
            localName: localName, advertisedServices: Array(Set(services.map { $0.uuidString.lowercased() })).sorted(),
            rssi: RSSI.intValue, isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue)
        onEvent?(.device(device))
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active === peripheral else { return }
        emit(.discoveringServices, "Connected. Discovering services and characteristic properties…")
        armTimeout("GATT discovery timed out. Export the partial report and try again.")
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if cancelling.remove(peripheral.identifier) != nil { return }
        guard active === peripheral else { return }
        release(cancel: false)
        let message = "Connection failed: \(error?.localizedDescription ?? "no details")"
        emit(.failed(message), message)
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if cancelling.remove(peripheral.identifier) != nil { return }
        guard active === peripheral else { return }
        release(cancel: false)
        if let error {
            let message = "Connection lost during inspection: \(error.localizedDescription)"
            emit(.failed(message), message)
        } else { emit(.disconnected, "Device disconnected. Collected metadata is retained for export.") }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active === peripheral else { return }
        if let error { fail("Service discovery failed: \(error.localizedDescription)"); return }
        let services = peripheral.services ?? []
        pendingServices = Set(services.map(ObjectIdentifier.init))
        publishServices(peripheral)
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active === peripheral else { return }
        if let error { fail("Characteristic discovery failed: \(error.localizedDescription)"); return }
        pendingServices.remove(ObjectIdentifier(service))
        publishServices(peripheral)
    }
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard active === peripheral else { return }
        fail("The device changed its services. Disconnect and inspect again.")
    }
}
