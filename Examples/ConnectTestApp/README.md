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

Both modes provide a **Clear logs** button beside the export controls. It clears the recorded events without disconnecting, resetting reading counters, or removing position/GATT snapshots. New events continue to appear while a session is active; exported reports still include their current summary and snapshot.

## ChessUp connection

The mode selector switches between **Board test** (registered drivers, such as the Go) and **ChessUp** (connection and service inspection before a game driver exists). Switching modes stops and disconnects the previous session. All Bluetooth code remains in the package.

The main flow follows the successful ChessUp 2 hardware test:

1. Open the official ChessUp app and wait for it to connect to the board.
2. Return to ConnectTestApp without force-closing the official app.
3. Select **ChessUp → Find ChessUp**. This looks up peripherals already connected to iOS that expose Nordic UART, then keeps names starting with `ChessUp` (case-insensitive).
4. Tap **Connect to ChessUp**. The module opens its own Core Bluetooth connection and inspects the services. It does not connect automatically just because a matching name was found.
5. Wait for **Connected · Bluetooth services inspected**. Tap **Disconnect** when finished.

No individual board UUID is stored in the app. Every search uses the identifiers returned by iOS, so the flow can work with another ChessUp or iPhone. Names such as `ChessUp 2` also match; unrelated and unnamed devices are omitted. A name match is a discovery filter, not device authentication or proof of protocol compatibility.

The manual name filter, all-device list, separate report selection, and always-visible UUID/GATT fields have been removed from this screen. **Technical details** retains the selected identifier, discovery source, signal/connectability information, and GATT snapshot. Identifiers are shown in the board list only when needed to distinguish multiple matches.

**Logs** keeps **Export report**, **Clear logs**, and expandable **Recent events** and **Test notes**. Exports still include the selected board's metadata, inspection completeness, firmware/conditions if entered, and the last 200 events. Export a failure before starting another search; a new search resets the discovery report. Disconnecting or clearing logs retains the collected snapshot.

### Optional advertisement scan

**More connection options → Scan nearby ChessUp** retains a 15-second advertisement scan, using the same name prefix filter. It is a fallback for boards that advertise directly. Direct advertisement discovery without the official app has not been verified on the tested ChessUp 2, so this is not the main connection path.

The system lookup is separate from advertisement scanning and does not enumerate all paired devices. Nordic UART is shared by other products. Rows and reports retain the discovery source; advertisement fields and RSSI are not invented for system-connected results. An empty result does not prove a vendor lock or that Bluetooth is disabled.

Reference: [Apple's retrieveConnectedPeripherals(withServices:) documentation](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/retrieveconnectedperipherals(withservices:)).

The successful test confirmed a local connection, Nordic UART write (`6e400002…`) and notify (`6e400003…`) characteristics, and the battery service. This mode still does not read values, write data, enable notifications, start games, or modify settings. Those operations need a ChessUp driver in the module. Independent reconnection without the official app remains unverified. The original Chessnut test remains under **Board test**.

### Diagnostic checks

| Check | Expected result |
| --- | --- |
| Find ChessUp after the official app connects | Shows matching system-connected UART peripherals only |
| Find another ChessUp or use another iPhone | Uses that discovery's identifier; no fixed board UUID |
| Scan nearby ChessUp | Shows only matching names if the board is advertising |
| Repeat advertisements | Updates the existing device entry rather than creating duplicates |
| Unrelated or unnamed UART peripheral | Does not appear in the ChessUp list |
| Connect to a selected board | Inspects UUIDs and property flags; no commands or value reads |
| Non-connectable advertisement | Connection button is disabled |
| Expand Technical details | Shows the snapshot and original transport status |
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

**Hardware status:** Go connection and incoming position frames observed. ChessUp 2 system lookup, local connection, and GATT inspection observed. Full Go square/light checks and ChessUp game-protocol communication remain to be validated.
