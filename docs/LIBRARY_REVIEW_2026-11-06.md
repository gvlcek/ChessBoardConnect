# Library review · 2026-11-06

Baseline: `aea1512`. This review covers the library under `Sources/ChessBoardConnect`, its tests, public contract, and documented hardware claims. The fixes below accompany this report on `main`; they do not change the existing `0.1.0` tag.

## Findings and corrections

| Priority | Finding | Correction and evidence |
| --- | --- | --- |
| P1 | The manager-unavailable path reused normal connection failure handling. It could issue cancellation while Bluetooth was unavailable, retain invalid peripheral handles after a controller reset, and leave a UUID blocked waiting for a cancellation callback. An unknown manager-state transition could also leave an existing connection marked ready. | Manager state now invalidates cached handles, active connection state, and cancellation bookkeeping without issuing Bluetooth commands. A fresh discovery/lookup is required. Reconnection is unavailable while the manager is off. Shared `PeripheralRegistry` tests exercise invalidation without a disconnect callback and subsequent rediscovery; a session-state test verifies unavailable states without creating a real manager. Full controller callback sequences still require hardware. |
| P2 | One corrupt Chessnut frame threw out the entire decoded notification batch, including valid frames before or after it. | Decode frames independently and emit invalid-data events in wire order. An invalid frame clears the reading and is logged; a later valid frame in the same notification can immediately recover it. A regression test failed with `invalidPacket` before the fix and passes afterward. Additional tests cover a corrupt final frame, fragmented batches, and unrelated characteristics. |
| P2 | Lights and position refresh bypassed the driver's mutating `prepare` method and the common preflight path. A future stateful read/light driver would not have its preparation applied; rejected preparation could also remove queued work too early. | All explicit commands use the same preparation and write-size checks. Queued light/refresh replacement and reading invalidation happen only after preparation succeeds. Stateful-driver fixtures exercise read/light batches and preservation of the original driver when preflight fails. Radio queue integration remains a separate validation boundary. |
| P3 | The no-position timeout wrote its status into the log twice: through the status observer and an explicit log call. | Removed the redundant call. |

[Apple's manager-state contract](https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanagerdidupdatestate(_:)) says commands require a powered-on manager and that states below powered off invalidate previously obtained peripheral objects. The implementation conservatively requires fresh discovery whenever Bluetooth becomes unavailable. It does not depend on a later per-device callback to recover.

## Architecture assessment

The current boundaries fit the scope of this early library:

- `BoardConnect` exposes observable normalized values and delegates work. It does not own app UI, a chess engine, PGN parsing, or game catalogs.
- `BluetoothSession` owns discovery, service/notification readiness, write serialization, pacing, timeouts, and connection cleanup. Its size reflects transport coordination, rather than unrelated product responsibilities.
- Manufacturer-specific encoding, parsing, and handshake state stay in drivers. Capabilities distinguish Chessnut sensor readings/lights from ChessUp move/FEN operations.
- `PeripheralRegistry` shares only connection bookkeeping between the normal session and metadata inspector. It compares cancellation object identity as well as UUID, so a callback from an old object cannot finish a replacement object's cancellation.
- Board/position/move values contain no Core Bluetooth objects. Normalized `BoardMove` construction validates square ranges and promotion characters; it intentionally does not validate chess legality.
- Core Bluetooth delegates and observable state are serialized on MainActor. This review found no synchronous disk/network operation or blocking sleep in the library. Parsing and log formatting still run there; their throughput has not been profiled on hardware.
- Timers use cancellable suspension and weak ownership. Commands are not automatically resent after uncertain acknowledgments. The example's file export remains outside the library and runs file generation off MainActor.

A broad rewrite or a view-model layer inside the library is not warranted by these findings. View models belong to consuming presentation code; the library already has a facade, transport coordinator, drivers, and value types.

## Remaining API and validation work

### Typed protocol completion before automated study playback

`ready` means that BLE notifications and writes are available. It does not mean that a ChessUp study handshake has finished, or that the previous move has been confirmed. Protocol progression currently appears in diagnostic `status` strings and local errors such as `busy` or `sessionNotInitialized`.

That is usable in the manual test app, but automated playback should have a typed command/session result or awaitable completion API. Consuming app logic should not parse English status strings or retry a possibly accepted move. Such an API needs to distinguish queued writes, protocol acceptance, timeouts/disconnection, and physical move events. This review leaves that feature design explicit instead of changing the public API or inventing a physical-execution guarantee.

### Transport coverage

Tests now cover connection bookkeeping and manager-unavailable handling without starting Bluetooth. They do not simulate an active `CBPeripheral`, the actual Core Bluetooth callback scheduler, notification loss, write backpressure, or every timeout/reconnect interleaving. A future injectable transport boundary would make more of those sequences testable; for now the physical regression checklist remains necessary.

### Protocol and hardware scope

- Chessnut fragmented/coalesced reports and malformed frames are covered by byte fixtures. ChessUp still assumes one recognized message per notification; do not generalize its framing without captures.
- Existing physical evidence covers basic flows on one Chessnut Go and one ChessUp 2. This review performed no fresh hardware test. Special moves, recovery, firmware variants, and sustained throughput remain pending.
- Drivers used with transactional preflight must be value types. A reference-type driver would share mutable state when staged. Contributor guidance now makes that requirement explicit.
- `BoardPosition.name(_:)` expects a normalized index in `0..<64`; its public documentation now states that precondition. Use `BoardPosition.index(_:)` when accepting user-entered coordinates.

## Validation

- 48 package/example-support tests passed with parallel execution: 11 new library tests in addition to the previous 37 tests.
- The corrupt-then-valid Chessnut regression was reproduced against the original implementation before applying the correction.
- The unsigned generic iPhone example build passed against the corrected library.
- No physical board run, radio-failure injection, Instruments trace, or claim of compatibility with additional firmware is included in these results.

## Physical follow-up

With each owned board, connect normally, receive a reading/move, send its supported command, disconnect, and reconnect. Then turn Bluetooth off/on, repeat discovery, and reconnect; separately power-cycle the board and verify that positions/moves are fresh. For ChessUp, explicitly reload FEN after reconnecting and confirm that missing acknowledgments disconnect rather than trigger a move retry. Repeat report export while the board streams events, using the example's responsiveness checklist.
