// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacFlow",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "MacFlow",
            path: "MacFlow",
            exclude: [
                "Resources",
                "Info.plist",
                "MacFlow.entitlements"
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist", "-Xlinker", "MacFlow/Info.plist"])
            ]
        ),
        .testTarget(
            name: "MacFlowTests",
            dependencies: ["MacFlow"],
            path: "MacFlowTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
    ]
)
