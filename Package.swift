// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Bobbin",
    platforms: [.macOS(.v14)],
    products: [
        // Product names are what land in `.build/<config>/`, so these carry
        // the shipped brand while the target names stay internal.
        .executable(name: "Bobbin", targets: ["BobbinGUI"]),
        .executable(name: "bobbin-icon", targets: ["BobbinIconTool"])
    ],
    targets: [
        .target(name: "BobbinCore"),
        .target(name: "BobbinIcon"),
        .executableTarget(
            name: "BobbinGUI",
            dependencies: ["BobbinCore", "BobbinIcon"]
        ),
        .executableTarget(
            name: "BobbinIconTool",
            dependencies: ["BobbinIcon"]
        ),
        .testTarget(
            name: "BobbinCoreTests",
            dependencies: ["BobbinCore", "BobbinIcon"]
        )
    ]
)
