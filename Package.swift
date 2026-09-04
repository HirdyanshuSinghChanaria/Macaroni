// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Macaroni",
    platforms: [
        // 14.4 is where Core Audio process taps landed — that's what makes
        // per-app volume possible at all.
        .macOS("14.4")
    ],
    targets: [
        .executableTarget(
            name: "Macaroni",
            path: "Sources/Macaroni"
        )
    ]
)
