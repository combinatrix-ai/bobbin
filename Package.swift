// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TinyHarnessGUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyHarnessGUI", targets: ["TinyHarnessGUI"]),
        .executable(name: "tiny-harness-icon", targets: ["TinyHarnessIconTool"])
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
