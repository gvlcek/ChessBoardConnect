# Changelog

Notable changes to ChessBoardConnect are recorded here, with the newest changes first.
Changes after the latest release are listed under **Unreleased** until a new version is published.

## [Unreleased]

### Added

- Optional `BoardGuidance` with a common prepare/guide/cancel workflow, typed progress, exact sensor matching, and reported-move completion evidence.
- Live `BoardConnect.events` and command IDs from `submit`, with explicit ChessUp protocol confirmations distinct from physical moves.
- Connection ownership during guidance, stable-reading handling, and cancellation cleanup without automatic move retries.
- A unified guidance form in the iPhone test app, consumer documentation, and coordinator/driver-fixture/example tests. The new complete workflow still requires physical validation.
- Library regression tests for radio-reset bookkeeping, cancellation object identity, corrupt Chessnut frame batches, and stateful read/light preparation.
- Example view-model tests for discovery, capabilities, command validation, readings, session cleanup, and export lifecycle races without Bluetooth.
- This changelog and contributor guidance for keeping it up to date.
- An invitation to help add and test more chessboard models, with the maintainer's contact email.

### Changed

- Separated the example screen from its view model and injectable board client; moved the position grid and native share sheet into dedicated views.
- Replaced the ChessUp-specific screen boolean with discovery presets; command sections now follow connected-board capabilities.
- Clarified that consuming apps build only the library; the example app and test targets remain separate.

### Fixed

- Clear stale peripheral handles and cancellation bookkeeping when Bluetooth becomes unavailable; require fresh discovery and avoid issuing stop/cancel commands while the manager is unavailable.
- Match pending cancellation callbacks by peripheral object identity as well as UUID in the connection and inspection transports.
- Preserve valid Chessnut readings around corrupt frames within a single notification, while logging and invalidating corrupt readings in wire order.
- Route lights and refresh through common transactional driver preparation and write-size preflight; replace queued work only after preparation succeeds.
- Avoid duplicate no-position timeout log entries.

## [0.1.0] - 2026-11-05

First public release. Requires Swift 6, iOS 17+ or macOS 14+.
The API and experimental board support may change before 1.0.

### Added

- A reusable Swift Package Manager library with a common `BoardConnect` interface, observable connection state, capability checks, normalized positions and moves, and board-independent commands.
- Bluetooth discovery, lookup of supported peripherals already connected to the operating system, connection management, notification subscriptions, queued writes, and reconnect controls.
- A classic Chessnut driver for position readings and square lights. The basic receive and light-control flow was verified on a Chessnut Go.
- An experimental ChessUp driver for full-FEN study setup, incoming moves, outgoing moves, and protocol acknowledgments. The basic study flow was verified on a ChessUp 2.
- Optional metadata-only BLE diagnostics for inspecting services and characteristic properties while investigating additional boards.
- A separate iPhone example app for testing connections, positions, lights, ChessUp study commands, and diagnostic log export without a consuming app.
- Bounded diagnostic logs and controls to clear them without disconnecting.
- Protocol and API tests, example report-export tests, and CI checks for package tests and an unsigned iPhone example build.
- English documentation, a contribution guide, an MIT license, and the project logo.
- A local signing configuration template so personal signing settings stay out of shared project files.

### Fixed

- Report generation now uses a frozen snapshot and performs formatting and file writing off MainActor; sharing uses a stable file and cleans up temporary exports.
- Reconnect attempts wait for an earlier connection cancellation to complete, reducing the risk of stale callbacks resetting a new connection.
- Connection readiness requires all expected notification subscriptions; subscription loss or service invalidation closes the connection.
- Multi-packet commands are checked against the BLE write limit before any packet is queued.
- Repeated position reports avoid duplicate state and status publications; pending refresh commands are coalesced.
- Position and coordinate parsing rejects oversized ranks and non-ASCII coordinate digits.

### Validation limits

Hardware checks cover basic flows on the owner's Chessnut Go and ChessUp 2.
Other models and firmware versions, special moves, recovery scenarios, and report export under a live hardware stream still need further validation.
See the [test app guide](Examples/ConnectTestApp/README.md#hardware-checklist) for hardware checks and remaining validation.

[Unreleased]: https://github.com/gvlcek/ChessBoardConnect/compare/0.1.0...HEAD
[0.1.0]: https://github.com/gvlcek/ChessBoardConnect/releases/tag/0.1.0
