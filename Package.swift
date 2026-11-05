// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ChessBoardConnect",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ChessBoardConnect", targets: ["ChessBoardConnect"])],
    targets: [
        .target(name: "ChessBoardConnect"),
        .testTarget(name: "ChessBoardConnectTests", dependencies: ["ChessBoardConnect"])
    ]
)
