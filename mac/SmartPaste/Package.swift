// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SmartPaste",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SmartPaste", targets: ["SmartPaste"]) 
    ],
    targets: [
        .executableTarget(
            name: "SmartPaste",
            path: "Sources"
        )
    ]
)
