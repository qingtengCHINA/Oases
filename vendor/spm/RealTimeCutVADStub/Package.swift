// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RealTimeCutVADLibrary",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "RealTimeCutVADLibrary", targets: ["RealTimeCutVADLibrary"]),
    ],
    targets: [
        .target(name: "RealTimeCutVADLibrary", path: "Sources/RealTimeCutVADLibrary"),
    ]
)
