// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LeetCodeAssistant",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "LeetCodeAssistant", targets: ["LeetCodeAssistant"])
    ],
    targets: [
        .executableTarget(
            name: "LeetCodeAssistant",
            path: "Sources/LeetCodeAssistant",
            exclude: ["Resources/RichContent/aliplayer"],
            resources: [
                .process("Resources"),
                .copy("Resources/RichContent/aliplayer")
            ]
        ),
        .testTarget(
            name: "LeetCodeAssistantTests",
            dependencies: ["LeetCodeAssistant"],
            path: "Tests/LeetCodeAssistantTests"
        )
    ]
)
