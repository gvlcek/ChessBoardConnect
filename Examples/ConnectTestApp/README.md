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

## BLE diagnostics for ChessUp discovery

The mode selector at the top switches between **Board test** (registered drivers, such as the Go) and **BLE diagnostics** (driver-independent discovery). Switching modes stops and disconnects the previous session. All Bluetooth code remains in the package.

To investigate a ChessUp 2:

1. Fully close the official ChessUp app and other board apps on nearby phones/tablets. Turn off other boards to reduce ambiguity.
2. Restart the ChessUp and leave it on its home screen. Record its firmware version; Wi-Fi may stay enabled.
3. Select **BLE diagnostics** and tap **Scan all BLE**. The scan lasts 15 seconds and includes devices with no registered driver or advertised name.
4. Look for `ChessUp`. If necessary, use the optional name filter; clear it to see unnamed advertisements. Each entry shows its iOS identifier, signal strength, advertised services, and connectability flag. Missing advertised service UUIDs do not imply that GATT services are absent.
5. Tap **Select for report** to capture an advertisement without connecting (including non-connectable devices). To investigate further, tap **Inspect GATT** on your own board. This opens a connection and lists all discovered services, characteristics, and property flags.
6. Enter the firmware and test conditions, then choose **Export BLE report**. Export even if the connection fails: it separates successful discovery from a failed connection or incomplete service inspection.
7. Disconnect before opening the official app again. You can compare scans before opening the official app and after fully closing it; when an app holds a connection, the board may advertise differently or stop advertising.

This mode does not read characteristic values, write data, enable notifications, start games, or modify board settings. It does perform normal BLE connection and GATT discovery requests. Successfully listing services does not imply support for chess moves. An empty scan alone does not establish that Bluetooth is disabled or restricted to the official app.

The exported report retains the selected advertisement and any collected service snapshot after disconnection, marks incomplete inspections, and records diagnostic events. Nearby devices that were never selected are not logged by name. A new scan starts a fresh report. Identifiers are assigned by iOS, not hardware MAC addresses. The original Chessnut test remains available under **Board test**.

### Diagnostic checks

| Check | Expected result |
| --- | --- |
| Scan with no driver for ChessUp | Its advertisement can still appear if the board is advertising |
| Repeat advertisements | Updates the existing device entry rather than creating duplicates |
| Device without a name | Appears as an unnamed device; clear the UI filter to see it |
| Select a non-connectable advertisement | Can export it without attempting a connection |
| Inspect a selected device | Lists UUIDs and property flags only; no commands or value reads |
| Disconnect after inspection | Retains the snapshot for export and releases the connection |
| Switch test modes | Disconnects the previous mode; no board commands are sent by diagnostics |
| Discovery times out or fails | Marks the report incomplete and keeps partial evidence |

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
