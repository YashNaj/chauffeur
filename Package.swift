// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "chauffeur",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "chauffeur", targets: ["chauffeur"])],
    targets: [
        .target(
            name: "ChauffeurBridge",
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("IOKit")]),
        .target(name: "ChauffeurCore", dependencies: ["ChauffeurBridge"]),
        .executableTarget(name: "chauffeur", dependencies: ["ChauffeurCore"]),
        .testTarget(
            name: "ChauffeurCoreTests",
            dependencies: ["ChauffeurCore"],
            resources: [.copy("Fixtures")]),
    ]
)
