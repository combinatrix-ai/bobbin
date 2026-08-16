// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Bobbin",
    platforms: [.macOS(.v14)],
    products: [
        // Product names are what land in `.build/<config>/`, so these carry
        // the shipped brand while the target names stay internal.
        .executable(name: "Bobbin", targets: ["TinyHarnessGUI"]),
        .executable(name: "bobbin-icon", targets: ["TinyHarnessIconTool"])
    ],
    targets: [
        .target(name: "TinyHarnessCore"),
        .target(name: "TinyHarnessIcon"),
        .executableTarget(
            name: "TinyHarnessGUI",
            dependencies: ["TinyHarnessCore", "TinyHarnessIcon"]
        ),
        .executableTarget(
            name: "TinyHarnessIconTool",
            dependencies: ["TinyHarnessIcon"]
        ),
        .testTarget(
            name: "TinyHarnessCoreTests",
            dependencies: ["TinyHarnessCore", "TinyHarnessIcon"]
        )
    ]
)
