// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LensDB",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "LensDB",
            path: "Sources/LensDB"
        )
    ]
)
