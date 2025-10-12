// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RsyncSwift",
    platforms: [
        .macOS(.v10_15)
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
            name: "RsyncSwift",
            targets: ["RsyncSwift"]
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
            pkgConfig: "librsync",
            providers: [
                .apt(["librsync-dev"]),
                .brew(["librsync"])
            ]
        ),

        // Shared connection library
        .target(
            name: "RsyncSwift",
            dependencies: ["Clibrsync"],
            path: "Sources/RsyncSwift"
        ),

        // Server executable
        .executableTarget(
            name: "Server",
            dependencies: ["RsyncSwift", "Clibrsync"],
            path: "Sources/Server"
        ),

        // Client executable
        .executableTarget(
            name: "Client",
            dependencies: ["RsyncSwift", "Clibrsync"],
            path: "Sources/Client"
        ),

        // HTTP Server executable
        .executableTarget(
            name: "HTTPServer",
            dependencies: [
                "RsyncSwift",
                "Clibrsync",
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/HTTPServer"
        ),

        // HTTP Client executable
        .executableTarget(
            name: "HTTPClient",
            dependencies: [
                "RsyncSwift",
                "Clibrsync",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/HTTPClient"
        ),
    ]
)
