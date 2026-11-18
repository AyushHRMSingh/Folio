// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "folio",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "FolioApp", targets: ["FolioApp"]),
        .executable(name: "foliotest", targets: ["foliotest"]),
    ],
    targets: [
        .target(name: "FolioCore", path: "Sources/FolioCore"),
        .executableTarget(name: "FolioApp", dependencies: ["FolioCore"], path: "Sources/FolioApp"),
        .executableTarget(name: "foliotest", dependencies: ["FolioCore"], path: "Sources/foliotest"),
    ],
    swiftLanguageModes: [.v5]
)
