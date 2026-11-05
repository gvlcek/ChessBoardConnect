# ConnectTestApp

An independent iPhone diagnostic app for testing **ChessBoardConnect**. It uses only `import ChessBoardConnect` and the public API. It does not include its own drivers, UUIDs, or manufacturer commands.

All app text, diagnostic report labels, and documentation are written in English.

This example is development tooling kept in the same repository as the library. It is not a Swift Package Manager product and is not compiled or installed when another app adds the `ChessBoardConnect` library. Its Xcode project is committed so maintainers can open it directly; no project generator is required.

## Run

1. Open `ConnectTestApp.xcodeproj` in this folder.
2. Copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`. Enter your Apple development team ID and a bundle identifier available in your account. The local file is ignored by Git; keep these overrides out of the Xcode Build Settings editor to avoid modifying the shared project.
3. Select a physical iPhone running iOS 17+ and run the **ConnectTestApp** scheme.
4. Turn on the Go and disconnect other apps. Tap **Scan**, allow Bluetooth access, and select the board from the list.

The project references the package at `../..` within this repository. It does not depend on another application project. Simulator execution is not evidence of hardware connectivity.

## Local signing

`Config/Signing.xcconfig` is the shared base configuration for Debug and Release. It uses a generic bundle identifier and optionally includes `Signing.local.xcconfig`. A fresh clone can build for Simulator or with signing disabled without creating the local file. Installing on an iPhone requires your own team and bundle identifier in that local file.

Only the shared configuration, template, and Xcode project are committed. The personal local file is ignored. Do not ignore `project.pbxproj`: source references, package dependencies, and other shared project settings must remain versioned. `skip-worktree` and `assume-unchanged` are not needed.

See [Apple's build configuration file documentation](https://developer.apple.com/documentation/xcode/adding-a-build-configuration-file-to-your-project).

## Screens and controls

- **Connection:** module status, scanning, stopping a scan, board selection, disconnecting, and reconnecting.
- **Capabilities:** reading positions, controlling lights, sending moves, and loading positions, as reported by the connected driver. The current Go implementation offers reading and lights. ChessUp provides an experimental move/FEN protocol, pending hardware validation.
- **Position:** all 64 received squares, coordinates, and the first FEN field, plus a counter and the last reading time. Disconnecting or requesting a new reading invalidates the previous position.
- **Lights:** enter squares such as `e2 e4` or `a1, h8`, turn them on, and turn all lights off. Invalid input is rejected.
- **Moves / FEN:** controls appear only when a driver advertises these capabilities; they are not simulated for the Go.
- **Diagnostics:** recent events, an optional firmware field, and log export (up to the module's last 200 events). The report includes the date, test app version, device type and iOS version, board name, capabilities, position, and TX/RX bytes.

An accepted command is **queued**. The app's confirmation does not prove that the firmware executed it or that the pieces were moved. Check the board and its readings.

**Export log** captures the board state once, prepares a text file off MainActor, and opens the system share sheet with that fixed file. Incoming events do not change the report while sharing. The temporary report is removed when the sheet is dismissed. Export failures appear as alerts; leaving the view cancels presentation and cleans up a pending export.

Both modes provide a **Clear logs** button beside the export controls. It clears the recorded events without disconnecting, resetting reading counters, or removing position/GATT snapshots. New events continue to appear while a session is active; exported reports still include their current summary and snapshot.

## ChessUp study protocol (experimental)

The **ChessUp** tab now uses the normal `BoardConnect` facade and its ChessUp driver, including notifications and commands. Driver-independent `BoardDiagnostics` remains available in the package for future investigations.

1. Connect the board in the official ChessUp app, then return without force-closing it.
2. Select **ChessUp → Find ChessUp**, then select your board. Discovery uses supported services and the `ChessUp` name prefix, with the current iOS identifier. No fixed board UUID is stored.
3. Wait for the connection status. The module enables UART notifications but sends no game commands automatically.
4. Put the pieces in the starting position. **Load position** contains its full FEN by default. Tap **Start study session with FEN**.
5. Wait for **ChessUp study session confirmed. Ready for moves.** The driver sends start (`64`), encoded FEN (`66`), then waits for FEN acknowledgment (`B1`) before sending study settings (`B9`). It waits for settings acknowledgment (`24`) before accepting moves.
6. Move `e2 → e4` physically. Look for **Last reported move** and RX `A3 35 04 01 04 03`, followed by TX acknowledgment `21`. Export the log with firmware and actual behavior if the bytes differ.
7. Start a fresh session at the initial position before testing an outgoing `e2 → e4` command. Wait for confirmation in the status, then observe the board and move the physical pieces as instructed by it. A queued command or protocol acknowledgment does not prove physical execution.
8. Repeat separately for Black, castling, captures, and promotion after the basic exchange works. Both-color replay and the study settings remain experimental on ChessUp 2.

The protocol exposes **Receive moves**, **Send moves**, and **Load positions**. It does not expose sensor positions, arbitrary lights, or a position refresh. Loaded FENs are commands, not sensor readings, so the test app does not show them as received positions. It does not validate chess legality or infer full game state.

Commands are serialized at the protocol level. Sending another command while waiting for a reply produces a local error. An eight-second missing-reply timeout disconnects the session; commands are not automatically retried because a move may already have been accepted. Reconnect and explicitly load FEN to recover. Writes that exceed the connection's maximum supported size fail rather than being truncated.

Promotion handling sends the piece choice after the move acknowledgment and waits for promotion acknowledgment. Incoming promotion produces an initial move followed by the same move with its promotion choice; consumers must treat that second event as an update, not another ply. Castling coordinates remain the standard king move (`e1g1`, etc.). Unknown notifications remain visible in raw RX logs; malformed recognized packets are discarded and logged. The parser currently expects each recognized protocol message in one notification, as in the inspected integration; split or combined messages require hardware evidence before extending framing.

**Export log** includes current status, last reported move, and up to 200 TX/RX/events. **Clear logs** keeps the connection. Switching tabs disconnects the previous session. The system-connected lookup remains distinct from advertisement scanning; unavailable RSSI is labeled accordingly.

Verified on one ChessUp 2: system lookup, local connection, FEN study initialization, receive e2e4, send e7e5 with the corresponding board lights, and receive e7e5 after physically moving the piece. Castling, captures, promotion, both-color replay, and recovery still require physical validation. Packet tests and successful compilation do not establish compatibility with all firmware.

## Hardware checklist

Record the board model, firmware, iPhone, and iOS version:

| Test | Expected result |
| --- | --- |
| Scan with the Go turned off | No new device appears; scanning finishes or can be stopped |
| Deny Bluetooth permission | Permission message appears and no connection is made |
| Scan and select the Go | Connects and receives at least one position |
| Starting position | All 64 squares match the physical pieces |
| Move and return a pawn | FEN and reading counter update with the board's reports |
| Manually capture and castle | All pieces appear on their final squares; the app does not validate legality |
| Light up `a1 h1 a8 h8` | The correct corners light up |
| Light up `e2 e4`, then turn off | Only those squares light up, then all lights turn off |
| Enter `z9` | A local alert appears and no command is sent |
| Disconnect | The current reading disappears and commands are disabled |
| Turn the Go off/on and reconnect | Fresh readings arrive rather than a stored position |
| Return from another app | Requests a fresh reading if still connected |
| Export the log | The report reflects the current state and includes TX/RX events |

If the Go reports only when pieces move, move and return a piece after requesting a position. When a failure occurs, export the log before its 200 events rotate out. Note the expected and actual squares and the reproduction steps.

## Development workflow

1. Modify Connect.
2. Run `swift test` from the package root.
3. Run this app on an iPhone and validate the change with hardware.
4. Update the dependency in your consuming app and verify its integration.

To check compilation only, run from the ChessBoardConnect repository root:

```sh
xcodebuild -project Examples/ConnectTestApp/ConnectTestApp.xcodeproj \
  -scheme ConnectTestApp -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/connect-testapp-build CODE_SIGNING_ALLOWED=NO build
```

**Hardware status:** Go e2e4 position decoding and e2/e4 lights on/off verified. ChessUp 2 basic FEN/send/receive study flow verified. Full edge-case and firmware coverage remains pending.

## Responsiveness regression check

On an iPhone with a board streaming positions, scroll the form, tap Export log, dismiss the share sheet, and repeat while moving pieces. Confirm the UI remains responsive, every shared file keeps the state captured at its own export tap, clear logs still works, and dismissing the sheet leaves the connection active. If a hang persists, record the board/firmware, iOS version, destination activity, and an Instruments Hangs/Time Profiler trace. The exporter tests verify file contents, event limits, snapshot stability, unique paths, errors, and cleanup; they do not replace device profiling or tests of third-party share extensions.
