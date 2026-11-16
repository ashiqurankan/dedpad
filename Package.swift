// swift-tools-version: 6.0

import PackageDescription
import Foundation

// dedpad is built for iPad with xtool (https://github.com/xtool-org/xtool) on Linux.
//
// `DedpadCore` is plain Foundation code (models, templates, storage, archives, export text)
// and also builds on Linux, so its unit tests run without the iOS SDK:
//
//     DEDPAD_CORE_ONLY=1 swift test
//
// (or `./scripts/test-core.sh`).
let coreOnly = ProcessInfo.processInfo.environment["DEDPAD_CORE_ONLY"] != nil

var products: [Product] = []
var targets: [Target] = [
    .target(
        name: "DedpadCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .testTarget(
        name: "DedpadCoreTests",
        dependencies: ["DedpadCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

if !coreOnly {
    // An xtool project contains exactly one library product: the app itself.
    products.append(.library(name: "Dedpad", targets: ["Dedpad"]))
    targets.append(
        .target(
            name: "Dedpad",
            dependencies: ["DedpadCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    )
} else {
    products.append(.library(name: "DedpadCore", targets: ["DedpadCore"]))
}

let package = Package(
    name: "Dedpad",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: products,
    targets: targets
)
