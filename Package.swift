// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TinyHarnessGUI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyHarnessGUI", targets: ["TinyHarnessGUI"])
    ],
    targets: [
        .target(name: "TinyHarnessCore"),
        .executableTarget(
            name: "TinyHarnessGUI",
            dependencies: ["TinyHarnessCore"]
        ),
        .testTarget(
            name: "TinyHarnessCoreTests",
            dependencies: ["TinyHarnessCore"]
        )
    ]
)
