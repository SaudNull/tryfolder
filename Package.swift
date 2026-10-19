// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "TryFolder",
    platforms: [.macOS(.v14)],
    products: [.library(name: "TryFolderCore", targets: ["TryFolderCore"]), .executable(name: "TryFolder", targets: ["TryFolder"])],
    targets: [
        .target(name: "TryFolderCore"),
        .executableTarget(name: "TryFolder", dependencies: ["TryFolderCore"]),
        .executableTarget(name: "TryFolderProbe", dependencies: ["TryFolderCore"], path: "Tools/Probe"),
        .testTarget(name: "TryFolderCoreTests", dependencies: ["TryFolderCore"])
    ],
    swiftLanguageModes: [.v5]
)
