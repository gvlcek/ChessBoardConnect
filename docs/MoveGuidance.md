# Move guidance

`BoardGuidance` coordinates one app-supplied move at a time through `BoardConnect`. It is an optional component of the same package. PGN parsing, chess legality, computing the resulting position, choosing the next move, and game UI stay in the consuming app.

This API is available on `main` after the `0.1.0` release. The release tag is unchanged. The complete guidance workflow still needs physical validation on both owned boards; earlier hardware checks cover the underlying connection, positions, lights, and ChessUp FEN/move commands.

## Connect, prepare, guide

Retain both objects for the lifetime of the session:

```swift
import Foundation
import ChessBoardConnect
import Combine

@MainActor
final class StudyBoard {
    let connect: BoardConnect
    let guidance: BoardGuidance
    private var subscriptions = Set<AnyCancellable>()

    init() {
        let connect = BoardConnect()
        self.connect = connect
        self.guidance = BoardGuidance(connect: connect)
        guidance.states.sink { state in
            switch state {
            case .ready:
                // Enable the app's action to guide the first move.
                break
            case .completed(let result):
                // Match result.request.id to the app's pending request.
                // Advance the app's game cursor here, then request the next move.
                print(result.evidence)
            case .failed(let error):
                print(error.localizedDescription)
            default:
                break
            }
        }.store(in: &subscriptions)
    }

    // Call after connecting and arranging the physical pieces.
    func prepare() throws {
        try guidance.prepareSession(
            fen: "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
        )
    }

    // Call after guidance.state becomes .ready.
    @discardableResult
    func guideE4() throws -> UUID {
        let move = try BoardMove(from: BoardPosition.index("e2")!, to: BoardPosition.index("e4")!)
        let target = try BoardPosition(fen: "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR")
        return try guidance.guideMove(move, expectedPosition: target)
    }
}
```

Use the normal discovery/connection methods on `connect` first. The library does not automatically connect, import games, or advance a game cursor. Observe `guidance.state` from SwiftUI or subscribe to `guidance.states` from Combine. State is stored before `states` emits, so a completion subscriber can submit the next move immediately. All guidance actions are MainActor-isolated.

`guideMove` returns a request UUID, also present in `.awaitingMove` and `.completed`. Only one request can be active. The host supplies a consistent move and target position. Basic checks reject a target that keeps a piece on the origin, leaves the destination empty, or disagrees with an explicit promotion choice; the library does not prove that the move is legal or that the rest of the target position is correct.

## Strategies and evidence

Strategies use capabilities, not board-name checks in the app:

| Capabilities | Preparation | Guidance | Completion evidence |
| --- | --- | --- | --- |
| Read positions + control lights (Chessnut Go) | Request a fresh reading and wait for an exact stable match with the starting placement | Indicate the move, request fresh readings, and update lights for every square differing from the target | `.sensorPosition`: the received placement matched the target for the settle interval |
| Send moves + receive moves + load positions (ChessUp) | Load the full FEN and wait for the manufacturer's session acknowledgment | Send the move and wait for both protocol acceptance and its matching physical move report | `.reportedMove`: the board reported the matching move; this does not verify all 64 squares |

When both sets of capabilities are available, the position/light strategy takes precedence. Other capability combinations report `unsupportedBoard`. Additional drivers still need protocol and hardware validation before guidance support is claimed.

The default sensor settle interval is 250 ms and can be configured with `BoardGuidance(connect:settleDuration:)`. Only exact matches count. Repeated identical reports do not restart the interval; a differing or invalidated reading cancels it. Cached `connect.position` and `connect.lastMove` never complete a new request: the coordinator consumes live events.

`.ready` means session preparation is complete. A move-reporting board's FEN acknowledgment is not proof of physical starting-piece placement; arrange those pieces before preparing. Similarly, protocol acceptance alone never completes a guided move.

Call `guidance.refresh()` when returning to the foreground to revalidate an active sensor target. It cancels any pending sensor settle interval and requests new data; it never retries a move-protocol command. The host app controls playback/background policy.

The expected position remains a target. In particular, a ChessUp completion never populates `connect.position` with an inferred sensor reading.

## States and errors

The normal lifecycle is `idle → preparing → ready → awaitingMove → completed`. The app can guide another move from `completed`, or prepare another position. The module never selects the next move itself.

- A second operation while preparing or waiting throws `busy` without replacing the current request.
- A wrong sensor placement keeps the request active and updates `differingSquares` and the lights.
- A different move reported by ChessUp fails the session; prepare it again after restoring the intended position and reconnecting. Unsolicited moves between requests also invalidate the session. Duplicate reports of the just-completed move are ignored while waiting for the next request.
- An incoming promotion without a piece choice remains incomplete. The matching promotion choice and the outgoing protocol confirmation are both required.
- Disconnects and manufacturer command timeouts fail the active guidance session. There is no automatic move retry.
- Human actions have no automatic deadline. The user can take time to arrange pieces or cancel explicitly.

## Ownership and cancellation

While guidance is active, it owns command submission on the connection. Raw `send`, `submit`, `refresh`, and `showLights` calls throw `ConnectError.busy`; another guidance object cannot acquire that connection. Read-only observations, diagnostic export, clearing logs, and explicit disconnect remain available. Call `guidance.cancel()` before switching to manual commands.

Cancellation releases ownership and ignores late replies/readings for that operation:

- A position/light board with no pending protocol command queues lights off and stays connected. As with any queued light command, physical execution is not guaranteed if the connection is closed immediately afterward.
- A move-protocol board closes the library's local connection and discards queued work. An already accepted move cannot be reliably withdrawn from the hardware, and another app may still own a system connection. Reconnect, arrange the pieces, and prepare a new session before resuming.

Dropping a guidance object schedules owner cleanup on MainActor. Explicit cancellation is the deterministic way to end the session. The test app also ends guidance when its screen is removed.

## Live low-level events

`BoardConnect.events` provides non-replaying `BoardEvent` values: connection state, sensor positions/invalidation, reported moves, and command confirmations. `submit(_:)` returns the UUID used by `commandConfirmed` for protocols with explicit confirmations. Commands without such a protocol acknowledgment do not synthesize one from a Bluetooth write acknowledgment.

The coordinator uses these typed events rather than interpreting English diagnostic status messages. Existing published properties and basic commands remain available when no guidance session owns the connection.

## Test on hardware

The independent example has **Unified move guidance** on both discovery presets:

1. Connect through **Board test** for Chessnut, or use the official ChessUp app followed by **ChessUp → Find ChessUp**.
2. Arrange the initial pieces, leave the initial full FEN in the guidance form, and tap **Prepare guidance session**.
3. Wait for **Ready to guide a move**. For Go this requires matching sensor readings; for ChessUp this is a protocol session confirmation.
4. Use `e2 → e4` with the default expected FEN and tap **Guide move**. Confirm the board indicates the move. The state must continue waiting until you move the physical piece.
5. Move the piece and verify the displayed completion evidence.
6. Set `e7 → e5` and use target placement `rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR`. Guide and complete Black's move.
7. Export the report with board/firmware notes. Test cancellation, reconnect, a wrong move/placement, captures, castling, en passant, and promotions separately. Standard castling uses king coordinates such as `e1g1`; Chess960 is not supported by this guidance contract.

Tests cover coordinator transitions, actual ChessUp protocol fixtures through an in-memory driver harness, exact target matching, request correlation, promotions, cancellation, stable-reading races, owner cleanup, and example view-model forwarding. They do not simulate a Bluetooth radio or establish that a firmware emits every physical report needed for guidance. The new end-to-end hardware flow, special moves, orientation changes, and firmware variants remain unverified until tested on real boards.
