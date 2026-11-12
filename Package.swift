// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "XChatTransferCore", platforms: [.macOS(.v13)], products: [.library(name: "TransferCore", targets: ["TransferCore"])], targets: [.target(name: "CSupport", path: "CSupport", publicHeadersPath: "include"), .target(name: "TransferCore", dependencies: ["CSupport"], path: "Core"), .testTarget(name: "TransferCoreTests", dependencies: ["TransferCore"], path: "Tests", exclude: ["ArchiveTests.m"])], swiftLanguageModes: [.v5])
