// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Marky",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.16.0"),
        .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.2.0"),
    ],
    targets: [
        .target(
            name: "MarkyCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]),
        .executableTarget(
            name: "Marky",
            dependencies: [
                "MarkyCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
            ]),
        .executableTarget(
            name: "MarkyCLI",
            dependencies: [
                "MarkyCore",
            ]),
        .testTarget(
            name: "MarkyTests",
            dependencies: ["Marky", "MarkyCore"]),
    ])
