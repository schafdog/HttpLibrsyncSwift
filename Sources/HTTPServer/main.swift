/*
 * librsync -- the library for network deltas
 *
 * Copyright (C) 2024 by Lars Erik Wik <lars.erik.wik@northern.tech>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * Converted to Swift with Hummingbird HTTP by Claude Code
 */

import Foundation
import Hummingbird
import RsyncSwift
import NIOCore
import NIOHTTP1
import Logging

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - Logging

var logger = Logger(label: "com.rsyncswift.httpserver")

// MARK: - HTTP Server

struct DeltaController {
    let rsync = Librsync()

    /// GET /signature?file=<filename>
    /// Generates and streams signature of the specified file
    @Sendable
    func generateSignature(_ request: Request, context: some RequestContext) async throws -> Response {
        // Get filename from query parameter
        guard let filename = request.uri.queryParameters.get("file") else {
            return Response(status: .badRequest, body: .init(byteBuffer: ByteBuffer(string: "Missing 'file' query parameter")))
        }

        let fileURL = URL(fileURLWithPath: filename)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "File not found: \(filename)")))
        }

        logger.info("Generating signature for file: \(filename)")

        // Stream signature using LibrsyncWrapper
        let signatureStream = rsync.signatureStream(from: fileURL)

        // Convert Data chunks to ByteBuffer for Hummingbird
        let byteBufferStream = signatureStream.map { data in
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return buffer
        }

        return Response(
            status: .ok,
            headers: [
                .contentType: "application/octet-stream",
                .transferEncoding: "chunked"
            ],
            body: .init(asyncSequence: byteBufferStream)
        )
    }

    /// POST /upload?file=<filename>
    /// Receives full file content and writes it
    @Sendable
    func uploadFile(_ request: Request, context: some RequestContext) async throws -> Response {
        // Get filename from query parameter
        guard let filename = request.uri.queryParameters.get("file") else {
            return Response(status: .badRequest, body: .init(byteBuffer: ByteBuffer(string: "Missing 'file' query parameter")))
        }

        logger.info("Receiving full file upload: \(filename)")

        // Open file for writing
        guard let file = fopen(filename, "wb") else {
            throw HTTPError(.internalServerError, message: "Failed to create file")
        }

        defer { fclose(file) }

        var totalBytes = 0

        // Read file content from request body
        for try await buffer in request.body {
            let nBytes = buffer.readableBytes

            if nBytes > 0 {
                buffer.withUnsafeReadableBytes { bytes in
                    let written = fwrite(bytes.baseAddress!, 1, nBytes, file)
                    if written != nBytes {
                        logger.error("Failed to write all bytes")
                    }
                    totalBytes += written
                }
                logger.debug("Received \(nBytes) bytes")
            }
        }

        logger.info("Successfully received file: \(filename) (\(totalBytes) bytes)")

        return Response(
            status: .ok,
            body: .init(byteBuffer: ByteBuffer(string: "File uploaded successfully. Received \(totalBytes) bytes"))
        )
    }

    /// POST /delta?file=<filename>
    /// Receives delta in request body, applies it to the file
    @Sendable
    func applyDelta(_ request: Request, context: some RequestContext) async throws -> Response {
        // Get filename from query parameter
        guard let filename = request.uri.queryParameters.get("file") else {
            return Response(status: .badRequest, body: .init(byteBuffer: ByteBuffer(string: "Missing 'file' query parameter")))
        }

        let fileURL = URL(fileURLWithPath: filename)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "File not found: \(filename)")))
        }

        logger.info("Applying delta to file: \(filename)")

        // Collect delta data from request body
        var deltaData = Data()
        for try await buffer in request.body {
            let nBytes = buffer.readableBytes
            if nBytes > 0 {
                buffer.withUnsafeReadableBytes { bytes in
                    deltaData.append(bytes.bindMemory(to: UInt8.self))
                }
                logger.debug("Received \(nBytes) bytes of delta")
            }
        }

        logger.info("Received complete delta (\(deltaData.count) bytes), applying patch...")

        // Apply patch using LibrsyncWrapper (with atomic rename)
        do {
            try await rsync.patch(fileURL, with: deltaData)
            logger.info("Successfully patched \(filename)")

            return Response(
                status: .ok,
                body: .init(byteBuffer: ByteBuffer(string: "Delta applied successfully. Updated \(filename)"))
            )
        } catch let error as LibrsyncError {
            logger.error("Patch failed: \(error.description)")
            throw HTTPError(.internalServerError, message: "Patch failed: \(error.description)")
        } catch {
            logger.error("Patch failed: \(error)")
            throw HTTPError(.internalServerError, message: "Patch failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Access Logging Middleware

struct AccessLogMiddleware<Context: RequestContext>: RouterMiddleware {
    func handle(_ request: Request, context: Context, next: (Request, Context) async throws -> Response) async throws -> Response {
        let startTime = Date()
        let method = request.method
        let uri = request.uri.description

        // Process request
        let response: Response
        do {
            response = try await next(request, context)
        } catch {
            // Log failed request
            let duration = Date().timeIntervalSince(startTime)
            logger.notice("\(method) \(uri) - ERROR [\(String(format: "%.3f", duration))s]")
            throw error
        }

        // Log successful request
        let duration = Date().timeIntervalSince(startTime)
        let status = response.status.code
        logger.notice("\(method) \(uri) - \(status) [\(String(format: "%.3f", duration))s]")

        return response
    }
}

// MARK: - Main Application

@main
struct HTTPServerApp {
    static func main() async throws {
        // Parse arguments
        var args = CommandLine.arguments

        // Check for help flag first (before any async operations)
        if args.contains("-h") || args.contains("--help") {
            printUsage(programName: args[0])
            return
        }

        // Default values
        var port: Int = 8081

        // Check for log level flags
        if let verboseIndex = args.firstIndex(of: "-v") ?? args.firstIndex(of: "--verbose") {
            logger.logLevel = .info
            args.remove(at: verboseIndex)
        } else if let debugIndex = args.firstIndex(of: "-vv") ?? args.firstIndex(of: "--debug") {
            logger.logLevel = .debug
            args.remove(at: debugIndex)
        } else {
            logger.logLevel = .notice
        }

        // Check for port flag
        if let portIndex = args.firstIndex(of: "-p") ?? args.firstIndex(of: "--port") {
            guard portIndex + 1 < args.count else {
                print("ERROR: Port flag requires a value")
                printUsage(programName: args[0])
                return
            }

            guard let parsedPort = Int(args[portIndex + 1]), parsedPort > 0, parsedPort <= 65535 else {
                print("ERROR: Invalid port number. Must be between 1 and 65535")
                return
            }

            port = parsedPort
            args.remove(at: portIndex + 1)
            args.remove(at: portIndex)
        }

        // Create router
        let router = Router()
        let controller = DeltaController()

        // Configure routes
        router.get("/signature", use: controller.generateSignature)
        router.post("/upload", use: controller.uploadFile)
        router.post("/delta", use: controller.applyDelta)

        // Add access logging middleware
        router.middlewares.add(AccessLogMiddleware())

        // Create and configure application
        let app = Application(
            router: router,
            configuration: .init(address: .hostname("127.0.0.1", port: port))
        )

        logger.notice("Starting HTTP server on http://127.0.0.1:\(port)")
        logger.notice("Endpoints:")
        logger.notice("  GET  /signature?file=<filename> - Get signature for any file")
        logger.notice("  POST /upload?file=<filename>    - Upload full file (when server doesn't have it)")
        logger.notice("  POST /delta?file=<filename>     - Apply delta to any file")

        try await app.runService()
    }

    static func printUsage(programName: String) {
        print("USAGE: \(programName) [OPTIONS]")
        print("")
        print("Start an HTTP server for rsync delta synchronization")
        print("")
        print("OPTIONS:")
        print("  -p, --port <PORT>    Port to listen on (default: 8081)")
        print("  -v, --verbose        Show progress updates (info level)")
        print("  -vv, --debug         Show detailed debugging information (debug level)")
        print("  -h, --help           Show this help message")
        print("")
        print("EXAMPLES:")
        print("  \(programName)")
        print("  \(programName) -p 8080")
        print("  \(programName) -p 8080 -v")
        print("  \(programName) --port 3000 --verbose")
    }
}
