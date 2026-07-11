// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RestEyes",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "RestEyesCore",
            path: "Sources/RestEyesCore"
        ),
        .executableTarget(
            name: "RestEyes",
            dependencies: ["RestEyesCore"],
            path: "Sources/RestEyes"
        ),
        .testTarget(
            name: "RestEyesCoreTests",
            dependencies: ["RestEyesCore"],
            path: "Tests/RestEyesCoreTests"
        ),
    ]
)
