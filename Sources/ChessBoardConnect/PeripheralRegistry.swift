import Foundation

/// Connection bookkeeping independent of Core Bluetooth objects and callback timing.
/// Cancellation callbacks belong to an object, not just a reusable peripheral UUID.
struct PeripheralRegistry<Peripheral: AnyObject> {
    var discovered: [UUID: Peripheral] = [:]
    var active: Peripheral?
    private var retiring: [UUID: ObjectIdentifier] = [:]

    var hasReferences: Bool { active != nil || !discovered.isEmpty || !retiring.isEmpty }

    func isRetiring(_ id: UUID) -> Bool { retiring[id] != nil }

    mutating func beginCancellation(_ peripheral: Peripheral, id: UUID) {
        retiring[id] = ObjectIdentifier(peripheral)
    }
    mutating func finishCancellation(_ peripheral: Peripheral, id: UUID) -> Bool {
        guard retiring[id] == ObjectIdentifier(peripheral) else { return false }
        retiring[id] = nil
        return true
    }
    mutating func invalidate() {
        active = nil
        discovered.removeAll()
        retiring.removeAll()
    }
}
