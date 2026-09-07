// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AppleMusicPresence",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AppleMusicPresence",
            path: "Sources/AppleMusicPresence",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
