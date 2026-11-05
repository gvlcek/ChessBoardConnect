# ChessBoardConnect

An independent Swift package for connecting electronic chessboards. Requires Swift 6, iOS 17+ or macOS 14+. No external dependencies: Foundation, Combine, and Core Bluetooth are Apple frameworks. Tests can run on macOS without an iPhone; full position and light validation still requires the physical board.

All project documentation, app text, diagnostic messages, and examples are written in English.

## Use in another app

In Xcode, choose Add Package Dependencies → Add Local, select this folder, and link the `ChessBoardConnect` product to your target. In a consuming Swift package:

```swift
// Package.swift: paths are relative to the consuming package.
.package(path: "../ChessBoardConnect")
// In the target's dependencies:
.product(name: "ChessBoardConnect", package: "ChessBoardConnect")
```

The host app must declare `NSBluetoothAlwaysUsageDescription` in its Info.plist. A sandboxed macOS app must also enable the Bluetooth entitlement. The package includes no UI and does not request permission until a scan starts.

```swift
import ChessBoardConnect
import Combine

@MainActor
final class MyBoardModel {
    let connect = BoardConnect()
    private var subscriptions = Set<AnyCancellable>()

    init() {
        connect.$position.sink { position in
            // nil means that no current reading is available.
            print(position?.fen ?? "No position")
        }.store(in: &subscriptions)

        connect.$state.sink { print($0) }.store(in: &subscriptions)
    }

    func search() { connect.scan() }
    func select(_ board: BoardDevice) throws { try connect.connect(board.id) }
    func guideE4() throws {
        guard connect.capabilities.contains(.controlLights) else { return }
        try connect.send(.setLights([BoardPosition.index("e2")!, BoardPosition.index("e4")!]))
    }
}
```

SwiftUI apps can observe `BoardConnect` with `@StateObject` and its published properties. Each subscriber receives updates independently; there is no single position callback that another screen could accidentally replace.

## Contract

- `devices`: discovered compatible devices, including identity, name, signal strength, and capabilities.
- `state`: typed states for scanning, connecting, receiving, disconnecting, and failure. `status` provides a diagnostic description.
- `position`: the placement of all 64 squares, normalized as the first FEN field. It does not infer the turn, castling rights, or legality.
- `lastMove`: the last move reported by a driver that emits moves. The current Chessnut driver delivers positions and does not infer moves.
- `capabilities`: whether the connected board supports reading positions, controlling lights, sending moves, or loading positions.
- `send`: common commands. Throws `unsupportedCapability` when the connected driver does not provide the requested operation. A successful return means the command was queued, not that a person moved the pieces.
- `showLights` / `refresh`: shortcuts for the corresponding commands.
- `disconnect`, `reconnect`, `stopScan`: explicit connection lifecycle. Disconnecting discards the current position and pending commands. Reconnecting requires a new reading.
- `logs`: up to 200 diagnostic events, without persistent storage. Timestamps use ISO 8601.
- `clearLogs()`: clears recorded events without disconnecting or changing readings. `BoardDiagnostics` offers the same method and retains its selected device and GATT snapshot. New events continue to be recorded.

Public square indices run from a8=0 to h8=7, then down to a1=56 through h1=63. Use `BoardPosition.index("e4")` to avoid depending on this numbering. Passing `[]` to the lights command turns all lights off. Updates are published on MainActor. Errors are reported through `ConnectError` or `state.failed`; an invalid incoming reading invalidates the current position.

## Board support

| Driver | Status | Current capabilities |
| --- | --- | --- |
| Classic Chessnut | Connection and incoming frames observed on Go; full hardware checklist pending | Read positions, control lights |
| ChessUp / ChessUp 2 | Local connection and GATT inspection observed on ChessUp 2; game driver not implemented or registered | None advertised |

The classic registry recognizes Chessnut names and explicitly excludes Move and Evo, which must not receive this protocol based only on the brand name. Go is the target for physical testing; compatibility with every classic firmware version is not guaranteed.

## Add another board

All changes belong inside this package:

1. Implement an internal `BoardDriver`: capabilities, Bluetooth profile, initial commands, command encoding, and notification decoding.
2. Add a factory and name filter to `DriverRegistry.standard`. Each connection creates a new driver, so buffers and protocol state are not shared.
3. Emit normalized `position` / `move` events. A driver can respond to the board through `write` events. Extend the handshake or transport inside the module if the hardware requires a different negotiation.
4. Add protocol fixtures and validate with real hardware. Consumer apps keep using the same interface and checking capabilities.

`BoardConnect` is the public facade, `BluetoothSession` handles transport, and drivers understand manufacturer messages. UUIDs, characteristics, and Bluetooth packets do not appear in the public interface. PGN import, game catalogs, study debounce, and target-position confirmation belong to the consuming app.

The package can be moved to an independent repository while keeping its `Package.swift`. Chess Dex uses a local dependency so development and testing do not require publishing a release.

## Independent test app

[`Examples/ConnectTestApp`](Examples/ConnectTestApp/README.md) contains an iPhone Xcode project that consumes the local package. It can scan for and connect to boards, inspect positions and capabilities, light up squares, reconnect, and export logs. It has no dependency on Chess Dex or game-study logic.

Open `Examples/ConnectTestApp/ConnectTestApp.xcodeproj`, select your signing team, and run on a physical iPhone. The example's guide includes a hardware checklist. Recommended workflow: package tests → test app with a physical board → Chess Dex integration.

## Driver-independent BLE diagnostics

`BoardDiagnostics` provides an optional metadata-only inspection API. It can inspect a selected device's GATT services and characteristic properties before a game driver exists. By default it includes all candidates, including unnamed devices; `BoardDiagnostics(namePrefix: "ChessUp")` limits results from both discovery paths to a case-insensitive peripheral/local name prefix. The filter uses current discovery identifiers rather than pinning a particular board UUID.

`checkConnectedDevices()` separately queries system-connected Nordic UART peripherals, including devices connected by other apps. This is useful when advertisement scanning does not find a board that the official app can connect to. It does not enumerate all paired Bluetooth devices, and UART is not unique to ChessUp. `BLEDiagnosticDevice.source` distinguishes these candidates from advertisements; missing advertisement metadata and RSSI are not invented. GATT inspection still requires a local connection.

It does not expose characteristic value reads, writes, notification subscriptions, or game commands. The public snapshots contain plain Swift values, not Core Bluetooth objects. Disconnected snapshots are retained for export; the connection state remains separate from inspection completion. `selectForReport` can capture an advertisement without connecting, including advertisements marked non-connectable.

The test app's **ChessUp** screen uses the filtered system lookup as its main flow. The manual filter and generic BLE list are no longer exposed there; technical details and a filtered advertisement fallback remain expandable. Generic inspection APIs are retained for investigating future boards. See the [test app guide](Examples/ConnectTestApp/README.md#chessup-connection) for the physical test procedure and observed hardware results. Tests use an injected metadata transport; real radio/GATT behavior must still be verified with your board. The driver registry and normal board connection API are unchanged.

## Tests

```sh
swift test
```

Tests cover known protocol bytes, orientation, fragmented packets, invalid input, disconnected-command behavior, multiple subscribers, and registration of an additional test driver. Tests do not turn on Bluetooth. No code from the Chessconnect extension has been incorporated.

Classic protocol sources:

- [Manufacturer documentation](https://github.com/chessnutech/Chessnut_eBoards)
- [Official SDK implementation](https://github.com/chessnutech/EasyLinkSDK/blob/main/sdk/EasyLink.cpp)

The lights command uses 10 bytes, matching the manufacturer's SDK code. Its README is ambiguous: it mentions 34 bytes while showing a 10-byte command. Confirm behavior on the Go before claiming validated compatibility.
