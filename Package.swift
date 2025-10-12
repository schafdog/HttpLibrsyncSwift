// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription
import Foundation

let librsyncPrefix: String = {
    // Detect typical Homebrew prefix at build time
    if FileManager.default.fileExists(atPath: "/opt/homebrew") {
        return "/opt/homebrew"
    } else if FileManager.default.fileExists(atPath: "/usr/local") {
        return "/usr/local"
    } else {
        return "/usr"
    }
}()

let package = Package(
    name: "HttpLibrsyncSwift",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Server executable (TCP)
        .executable(
            name: "Server",
            targets: ["Server"]
        ),
        // Client executable (TCP)
        .executable(
            name: "Client",
            targets: ["Client"]
        ),
        // HTTP Server executable
        .executable(
            name: "HTTPServer",
            targets: ["HTTPServer"]
        ),
        // HTTP Client executable
        .executable(
            name: "HTTPClient",
            targets: ["HTTPClient"]
        ),
        // Library for shared connection code
        .library(
            name: "LibrsyncSwift",
            targets: ["LibrsyncSwift"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
    ],
    targets: [
        // System library wrapper for librsync
        .systemLibrary(
            name: "Clibrsync",
            path: "Sources/Clibrsync",
            providers: [
                .apt(["librsync-dev"]),
                .brew(["librsync"])
            ]
        ),

        // Shared connection library
        .target(
            name: "LibrsyncSwift",
            dependencies: ["Clibrsync"],
            path: "Sources/LibrsyncSwift",
            exclude: ["README.md"],
            swiftSettings: [
                .unsafeFlags(["-I\(librsyncPrefix)/include"], .when(platforms: [.macOS])),
            ],
            linkerSettings: [
                .unsafeFlags(["-L\(librsyncPrefix)/lib"], .when(platforms: [.macOS])),
                .linkedLibrary("rsync")
            ]
        ),

        // Server executable
        .executableTarget(
            name: "Server",
            dependencies: ["LibrsyncSwift", "Clibrsync"],
            path: "Sources/Server"
        ),

        // Client executable
        .executableTarget(
            name: "Client",
            dependencies: ["LibrsyncSwift", "Clibrsync"],
            path: "Sources/Client"
        ),

        // HTTP Server executable
        .executableTarget(
            name: "HTTPServer",
            dependencies: [
                "LibrsyncSwift",
                "Clibrsync",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/HTTPServer"
        ),

        // HTTP Client executable
        .executableTarget(
            name: "HTTPClient",
            dependencies: [
                "LibrsyncSwift",
                "Clibrsync",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/HTTPClient"
        ),

        // Tests (Swift Testing - works on all platforms with Swift 6.1+)
        .testTarget(
            name: "LibrsyncSwiftTests",
            dependencies: [
                "LibrsyncSwift",
                "Clibrsync"
            ],
            path: "Tests/LibrsyncSwiftTests",
            exclude: [
                "README.md",
                "DummyTests.swift"  // Old placeholder, no longer needed
            ]
        ),
    ]
)
