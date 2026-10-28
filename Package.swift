// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FilePicker",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "FSEngine", path: "Sources/FSEngine"),
        .executableTarget(
            name: "FilePicker",
            dependencies: ["FSEngine"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Carbon")]
        ),
        .executableTarget(name: "fsbench", dependencies: ["FSEngine"]),
        .testTarget(name: "FSEngineTests", dependencies: ["FSEngine"]),
    ],
    swiftLanguageVersions: [.v5]
)
