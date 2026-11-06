# Pre-publication review · 2026-11-05

A subsequent [library review](LIBRARY_REVIEW_2026-11-06.md) records additional findings, corrections, and current validation limits.

Reviewed the public API, main-actor/Combine publication, BLE discovery and lifecycle, write queue and timeouts, both drivers/codecs, metadata diagnostics, example app, signing, report export, tests, documentation, and repository contents.

## Findings addressed

| Priority | Finding and trigger | Change | Evidence / limit |
| --- | --- | --- | --- |
| P1 | The example constructed a ShareLink payload in `body`; each live update rebuilt the report and could change the payload during sharing. | Export is an explicit action: capture a Sendable snapshot, format and write in a detached task, present the native share controller with a fixed file URL. Cancelled presentation and dismissal clean up app-owned files. | Real exporter tests cover a frozen snapshot, last-200 limit, unique files, errors, and cleanup. The reported iPhone hang still needs physical reproduction/profiling; static analysis does not prove a sole cause. |
| P1 | Disconnect/reset immediately allowed connecting the same CBPeripheral before its old cancellation callback. The old callback could reset the new connection. | Track retiring peripheral IDs, reject premature reconnects, and publish reconnect availability when cancellation finishes. A failed connection is reset directly rather than being cancelled a second time. | Code-path review and compilation. Adapter behavior needs a physical disconnect/reconnect regression test. |
| P1 | A multi-packet study start could send reset before discovering that its FEN exceeded the BLE write limit. | Preflight every packet before committing driver state or sending the first packet. Keep the transport-side limit check for driver-generated replies. | Batch-preflight tests reject the FEN before the reset can be enqueued and preserve original driver state. The actual negotiated maximum still comes from Core Bluetooth. |
| P2 | Readiness could be published before every required notification characteristic was found. Loss of notifications or service invalidation left stale command handles usable. | Require the complete notification set; fail and release the connection if subscriptions stop or services change. | Compile validation; no claim of a simulated radio failure test. |
| P2 | Every repeated position also published/logged the same connection state. This duplicated log traffic and view invalidations. | Publish state/status only when they change; keep all raw RX events and received position events. Coalesce queued refresh commands. | Packet tests preserved; hardware stream should still increment the example's reading counter. |
| P2 | Placement parsing expanded invalid ranks before checking length, and coordinate parsing accepted non-ASCII digits. | Bound each rank while parsing and require ASCII digits. | Tests reject an oversized rank, invalid glyphs, invalid coordinates, and exercise fragmented/noisy extended reports. |

## Architecture decisions

- Keep UI state and Core Bluetooth callbacks serialized on MainActor. Packet work is bounded and small; moving all Bluetooth state to arbitrary background tasks would add races without evidence of a benefit.
- File generation and disk I/O belong off MainActor. UI presentation and UIKit metadata access belong on it. [Apple responsiveness guidance](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).
- Driver protocol acknowledgments are separate from Core Bluetooth write acknowledgments and from a user's physical action. Never retry a possibly accepted move automatically.
- The library owns hardware protocols and normalized values. The example owns UIKit, report files, sharing, and visual diagnostics. No consumer application is required.
- Personal signing remains in the ignored local config. The shared project builds unsigned without it.

## Hardware evidence supplied by the owner

- Chessnut Go: connect, decode physical e2e4, illuminate e2/e4, and turn the lights off.
- ChessUp 2: system-connected discovery, FEN study setup, receive physical e2e4, send e7e5 with corresponding lights, and receive e7e5 after the physical move.

These are basic flows on individual boards, not compatibility certification across models or firmware versions. Promotions, castling, captures, recovery, and both-color historical replay still require physical coverage.

## Remaining limitations and regression procedure

- Repeat the export while a real board streams positions, dismiss it repeatedly, test a destination activity, clear logs, and verify that sharing does not disconnect. Use Instruments Hangs/Time Profiler if the issue persists. Simulator export was opened and dismissed twice, with temporary-file cleanup verified in the app container. This cannot model BLE throughput or third-party share extensions.
- Test immediate reconnect attempts, board power loss, Bluetooth off/on, service invalidation, and missing command acknowledgments on hardware. BLE lifecycle fixes are not claimed as adapter integration tests.
- ChessUp framing currently follows the inspected integration's one-message-per-notification handling. Unknown packets are retained in raw logs. Fragmented/coalesced ChessUp messages need real captures before generalizing the parser. Chessnut framing is length-based and tested with fragments/coalescing/noise.
- The example's live position grid still refreshes as readings arrive. If profiling identifies layout as the remaining bottleneck, throttle visual snapshots while retaining the full library event stream.
- Exported logs can contain peripheral identifiers, board names, positions, and optional notes. Review them before posting publicly. Temporary files are app-owned and removed on dismissal; files left by process termination are subject to OS temporary-directory cleanup.

## Repository readiness

MIT license selected by the owner. Shared docs/UI use English. Current tracked files are independent of any other app. Existing commit history is intentionally retained at the owner's request; old versions remain browsable. CI defines package/example-support tests and an unsigned iPhone build. See CONTRIBUTING.md for reproduction instructions. Only tracked, reviewed files are published; personal signing is excluded. The approved logo commits are preserved.

## Validation result

- 24 package/example-support tests passed on macOS.
- Unsigned generic iPhone build passed with no personal signing file.
- iPhone 17 Pro / iOS 26.1 Simulator build passed; native report export opened and dismissed twice. Temporary report cleanup was verified in the app container.
- No device profiling or fresh BLE regression run was performed during this review. Existing hardware evidence is listed separately above.
- No common credential patterns were found by a heuristic scan of existing Git blobs; that scan is not a guarantee against every possible secret format.

## Post-release example architecture review · 2026-11-05

The original example put its subscriptions, command validation, reading counters, connection actions, and report lifecycle inside `ConnectionLabView`. It also selected board-specific UI with a `chessUpOnly` boolean. The original 24 tests covered the library and report-file exporter, but not that screen's presentation logic.

The example now uses a `ConnectionLabViewModel` with an injectable example-only `LabBoardClient`, exporter, and clock. The live adapter consumes the library's public publishers and forwards their emitted values directly. The view renders presentation state and delegates actions; the board grid and native share sheet are separate views. `LabConfiguration` presets describe discovery instructions, while command sections depend on the connected board's capabilities. Changing presets creates a new model and stops the old session. No public library API or driver implementation changed.

Added 13 tests covering discovery (including a future configuration), capability gating, invalid inputs, command failures, received readings/moves, foreground refresh, session cleanup, live adapter initial/disconnect updates, stable export snapshots, error recovery, dismissal cleanup, and cancelled export completions racing with a new export.

Validation: all 37 tests passed on macOS; unsigned generic iPhone and iPhone Simulator builds passed. In Simulator, switching to ChessUp updated the discovery action/instructions, exporting opened the native share sheet with a text report, dismissal restored the export button, and switching back created a clean Board test screen. These checks do not establish physical Bluetooth behavior after the refactor; repeat the example's hardware checklist with both boards.
