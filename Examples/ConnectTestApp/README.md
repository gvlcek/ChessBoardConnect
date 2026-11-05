# ConnectTestApp

An iPhone diagnostic app for testing **ChessBoardConnect without Chess Dex**. It uses only `import ChessBoardConnect` and the public API. It does not include its own drivers, UUIDs, or manufacturer commands.

All app text, diagnostic report labels, and documentation are written in English.

## Run

1. Open `ConnectTestApp.xcodeproj` in this folder.
2. Select the **ConnectTestApp** target → Signing & Capabilities → choose your development team. No team is configured in the project; change the Bundle Identifier to one available in your account if needed.
3. Select a physical iPhone running iOS 17+ and run the **ConnectTestApp** scheme.
4. Turn on the Go and disconnect other apps. Tap **Scan**, allow Bluetooth access, and select the board from the list.

The project references the package at `../..`, so it works both from an independent ChessBoardConnect clone and from the local copy inside Chess Dex. It does not depend on ChessDex.xcodeproj. Simulator execution is not evidence of hardware connectivity.

## Screens and controls

- **Connection:** module status, scanning, stopping a scan, board selection, disconnecting, and reconnecting.
- **Capabilities:** reading positions, controlling lights, sending moves, and loading positions, as reported by the connected driver. The current Go implementation offers reading and lights. ChessUp is not implemented yet.
- **Position:** all 64 received squares, coordinates, and the first FEN field, plus a counter and the last reading time. Disconnecting or requesting a new reading invalidates the previous position.
- **Lights:** enter squares such as `e2 e4` or `a1, h8`, turn them on, and turn all lights off. Invalid input is rejected.
- **Moves / FEN:** controls appear only when a driver advertises these capabilities; they are not simulated for the Go.
- **Diagnostics:** recent events, an optional firmware field, and log export (up to the module's last 200 events). The report includes the date, test app version, device type and iOS version, board name, capabilities, position, and TX/RX bytes.

An accepted command is **queued**. The app's confirmation does not prove that the firmware executed it or that the pieces were moved. Check the board and its readings.

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
4. Update the dependency in Chess Dex and verify its integration.

To check compilation only, run from the ChessBoardConnect repository root:

```sh
xcodebuild -project Examples/ConnectTestApp/ConnectTestApp.xcodeproj \
  -scheme ConnectTestApp -configuration Debug -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/connect-testapp-build CODE_SIGNING_ALLOWED=NO build
```

**Status:** iPhone compilation verified; physical Go testing pending. Counters, logs, and declared capabilities are diagnostic aids, not firmware compatibility certification.
