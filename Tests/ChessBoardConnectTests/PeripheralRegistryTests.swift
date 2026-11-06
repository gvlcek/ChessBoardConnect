import Foundation
import CoreBluetooth
import XCTest
@testable import ChessBoardConnect

final class PeripheralRegistryTests: XCTestCase {
    func testRadioInvalidationDropsHandlesAndRetirementsWithoutWaitingForCallbacks() {
        let id = UUID()
        let old = NSObject()
        var peers = PeripheralRegistry<NSObject>()
        peers.discovered[id] = old
        peers.active = old
        peers.beginCancellation(old, id: id)
        XCTAssertTrue(peers.hasReferences)
        XCTAssertTrue(peers.isRetiring(id))

        // Bluetooth becoming unavailable is sufficient, even if no disconnect arrives.
        peers.invalidate()
        XCTAssertFalse(peers.hasReferences)
        XCTAssertTrue(peers.discovered.isEmpty)
        XCTAssertNil(peers.active)
        XCTAssertFalse(peers.isRetiring(id))

        let rediscovered = NSObject()
        peers.discovered[id] = rediscovered
        peers.active = rediscovered
        XCTAssertTrue(peers.active === rediscovered)
        XCTAssertFalse(peers.isRetiring(id), "Old cancellation must not block a rediscovered board")
        XCTAssertFalse(peers.finishCancellation(old, id: id))
        XCTAssertTrue(peers.active === rediscovered)
    }
    func testCancellationRequiresTheMatchingObjectNotOnlyItsUUID() {
        let id = UUID()
        let old = NSObject()
        let replacement = NSObject()
        var peers = PeripheralRegistry<NSObject>()
        peers.beginCancellation(old, id: id)
        XCTAssertFalse(peers.finishCancellation(replacement, id: id))
        XCTAssertTrue(peers.isRetiring(id))
        XCTAssertTrue(peers.finishCancellation(old, id: id))
        XCTAssertFalse(peers.isRetiring(id))
        XCTAssertFalse(peers.finishCancellation(old, id: id), "Duplicate callbacks must be harmless")
    }
    func testOldCallbackAfterInvalidationCannotFinishNewObjectsCancellation() {
        let id = UUID()
        let old = NSObject()
        let current = NSObject()
        var peers = PeripheralRegistry<NSObject>()
        peers.beginCancellation(old, id: id)
        peers.invalidate()
        peers.discovered[id] = current
        peers.beginCancellation(current, id: id)
        XCTAssertFalse(peers.finishCancellation(old, id: id))
        XCTAssertTrue(peers.isRetiring(id))
        XCTAssertTrue(peers.finishCancellation(current, id: id))
    }
    func testStartingNewDiscoveryPreservesAnOutstandingCancellation() {
        let id = UUID()
        let peer = NSObject()
        var peers = PeripheralRegistry<NSObject>()
        peers.discovered[id] = peer
        peers.beginCancellation(peer, id: id)
        peers.discovered.removeAll()
        peers.discovered[id] = peer
        XCTAssertTrue(peers.isRetiring(id), "Scanning is not a manager reset")
        XCTAssertTrue(peers.finishCancellation(peer, id: id))
    }

    @MainActor
    func testUnavailableManagerStatesPublishFailureWithoutCreatingBluetoothManager() {
        let session = BluetoothSession()
        session.handleBluetoothState(.unknown)
        XCTAssertEqual(session.state, .idle)
        XCTAssertEqual(session.status, "Waiting for Bluetooth…")
        for state in [CBManagerState.poweredOff, .resetting, .unauthorized, .unsupported] {
            session.handleBluetoothState(state)
            guard case .failed = session.state else { return XCTFail("Unavailable state must fail") }
            XCTAssertFalse(session.ready)
            XCTAssertFalse(session.scanning)
            XCTAssertFalse(session.canReconnect)
            XCTAssertFalse(session.connectedOrConnecting)
            XCTAssertTrue(session.devices.isEmpty)
            XCTAssertTrue(session.capabilities.isEmpty)
            XCTAssertNil(session.position)
            XCTAssertNil(session.lastMove)
            XCTAssertThrowsError(try session.send(.requestPosition)) {
                XCTAssertEqual($0 as? ConnectError, .notConnected)
            }
        }
        session.handleBluetoothState(.poweredOn)
        XCTAssertFalse(session.ready, "Restoring Bluetooth does not reconnect or send commands automatically")
    }
}
