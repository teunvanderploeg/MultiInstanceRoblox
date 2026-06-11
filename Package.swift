// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MultiInstanceRoblox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MultiInstanceRoblox", targets: ["MultiInstanceRoblox"])
    ],
    targets: [
        .executableTarget(
            name: "MultiInstanceRoblox",
            path: "Sources/MultiInstanceRoblox"
        )
    ]
)
