// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jobbar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Jobbar", path: "Sources/Jobbar")
    ]
)
