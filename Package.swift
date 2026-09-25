// swift-tools-version: 6.0
import Foundation
import PackageDescription

let isAppStore = ProcessInfo.processInfo.environment["MARKY_APP_STORE"] == "1"

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftlang/swift-cmark.git", branch: "gfm"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.16.0"),
    .package(url: "https://github.com/orchetect/MenuBarExtraAccess", from: "1.2.0"),
]
if !isAppStore {
    packageDependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"))
}

var markyDependencies: [Target.Dependency] = [
    "MarkyCore",
    .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
    .product(name: "MenuBarExtraAccess", package: "MenuBarExtraAccess"),
]
if !isAppStore {
    markyDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "Marky",
    platforms: [
        .macOS(.v15),
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "MarkyCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]),
        .executableTarget(
            name: "Marky",
            dependencies: markyDependencies,
            exclude: ["SmartFill/gliner_worker.py"]),
        .executableTarget(
            name: "MarkyCLI",
            dependencies: [
                "MarkyCore",
            ]),
        .testTarget(
            name: "MarkyTests",
            dependencies: ["Marky", "MarkyCore"],
            resources: [.copy("Fixtures")]),
    ])
