// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacDroid",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "MacDroid", targets: ["MacDroid"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0")
    ],
    targets: [
        .executableTarget(
            name: "MacDroid",
            dependencies: [
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ],
            resources: [
                .copy("Resources")
            ],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("AppKit")
            ]
        ),
        .testTarget(
            name: "MacDroidTests",
            dependencies: ["MacDroid"]
        )
    ]
)
