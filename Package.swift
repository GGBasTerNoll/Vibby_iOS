// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Vibby",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "Vibby",
            targets: ["Vibby"]
        ),
    ],
    targets: [
        .target(
            name: "Vibby",
            path: "Sources/Vibby"
        ),
    ],
    swiftLanguageModes: [.v5]
)
