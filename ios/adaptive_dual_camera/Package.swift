// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "adaptive_dual_camera",
    platforms: [.iOS("12.0")],
    products: [
        .library(name: "adaptive-dual-camera", targets: ["adaptive_dual_camera"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "adaptive_dual_camera",
            dependencies: [.product(name: "FlutterFramework", package: "FlutterFramework")]
        )
    ]
)
