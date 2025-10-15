// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

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
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.9.0"),
        .package(url: "https://github.com/schafdog/LibrsyncSwift", from: "1.0.5"),
    ],
    targets: [
        // Server executable
        .executableTarget(
            name: "Server",
            dependencies: [
                .product(name: "LibrsyncSwift", package: "LibrsyncSwift"),
            ],
            path: "Sources/Server"
        ),

        // Client executable
        .executableTarget(
            name: "Client",
            dependencies: [
                .product(name: "LibrsyncSwift", package: "LibrsyncSwift"),
            ],
            path: "Sources/Client"
        ),

        // HTTP Server executable
        .executableTarget(
            name: "HTTPServer",
            dependencies: [
                .product(name: "LibrsyncSwift", package: "LibrsyncSwift"),
                .product(name: "Hummingbird", package: "hummingbird"),
            ],
            path: "Sources/HTTPServer"
        ),

        // HTTP Client executable
        .executableTarget(
            name: "HTTPClient",
            dependencies: [
                .product(name: "LibrsyncSwift", package: "LibrsyncSwift"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
            ],
            path: "Sources/HTTPClient"
        ),
    ]
)
