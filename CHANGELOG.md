# Changelog

Notable changes to ChessBoardConnect are recorded here, with the newest changes first.
Changes after the latest release are listed under **Unreleased** until a new version is published.

## [Unreleased]

### Added

- This changelog and contributor guidance for keeping it up to date.
- An invitation to help add and test more chessboard models, with the maintainer's contact email.

### Changed

- Clarified that consuming apps build only the library; the example app and test targets remain separate.

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
- English documentation, contribution and review guides, an MIT license, and the project logo.
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
See [the review notes](docs/REVIEW.md) for evidence and remaining checks.

[Unreleased]: https://github.com/gvlcek/ChessBoardConnect/compare/0.1.0...HEAD
[0.1.0]: https://github.com/gvlcek/ChessBoardConnect/releases/tag/0.1.0
