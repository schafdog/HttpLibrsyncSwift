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
import Clibrsync
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
    /// GET /signature?file=<filename>
    /// Generates and streams signature of the specified file
    @Sendable
    func generateSignature(_ request: Request, context: some RequestContext) async throws -> Response {
        // Get filename from query parameter
        guard let filename = request.uri.queryParameters.get("file") else {
            return Response(status: .badRequest, body: .init(byteBuffer: ByteBuffer(string: "Missing 'file' query parameter")))
        }

        // Verify file exists
        guard FileManager.default.fileExists(atPath: filename) else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "File not found: \(filename)")))
        }

        logger.info("Generating signature for file: \(filename)")

        // Open file
        guard let file = rs_file_open(filename, "rb", 0) else {
            throw HTTPError(.internalServerError, message: "Failed to open file")
        }

        // Get file size and signature parameters
        let fsize = rs_file_size(file)
        var sigMagic: rs_magic_number = rs_magic_number(rawValue: 0)
        var blockLen: Int = 0
        var strongLen: Int = 0

        let res = rs_sig_args(fsize, &sigMagic, &blockLen, &strongLen)
        guard res == RS_DONE else {
            rs_file_close(file)
            throw HTTPError(.internalServerError, message: "Failed to get signature parameters")
        }

        // Start generating signature
        guard let job = rs_sig_begin(blockLen, strongLen, sigMagic) else {
            rs_file_close(file)
            throw HTTPError(.internalServerError, message: "Failed to create signature job")
        }

        // Stream signature in response
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/octet-stream",
                .transferEncoding: "chunked"
            ],
            body: .init(asyncSequence: SignatureStream(file: file, job: job))
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
        guard let file = rs_file_open(filename, "wb", 1) else {
            throw HTTPError(.internalServerError, message: "Failed to create file")
        }

        var totalBytes = 0

        // Read file content from request body
        for try await buffer in request.body {
            var byteBuffer = buffer
            let nBytes = byteBuffer.readableBytes

            if nBytes > 0 {
                byteBuffer.withUnsafeReadableBytes { bytes in
                    let written = fwrite(bytes.baseAddress!, 1, nBytes, file)
                    if written != nBytes {
                        logger.error("Failed to write all bytes")
                    }
                    totalBytes += written
                }
                logger.debug("Received \(nBytes) bytes")
            }
        }

        fclose(file)

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

        // Verify file exists
        guard FileManager.default.fileExists(atPath: filename) else {
            return Response(status: .notFound, body: .init(byteBuffer: ByteBuffer(string: "File not found: \(filename)")))
        }

        logger.info("Applying delta to file: \(filename)")

        let newFilename = "." + filename + ".new"

        // Open new file
        guard let newFile = rs_file_open(newFilename, "wb", 1) else {
            throw HTTPError(.internalServerError, message: "Failed to create new file")
        }

        // Open basis file
        guard let oldFile = rs_file_open(filename, "rb", 0) else {
            fclose(newFile)
            throw HTTPError(.internalServerError, message: "Failed to open basis file")
        }

        guard let job = rs_patch_begin(rs_file_copy_cb, oldFile) else {
            fclose(newFile)
            fclose(oldFile)
            throw HTTPError(.internalServerError, message: "Failed to create patch job")
        }

        var bufs = rs_buffers_t()
        var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
        var outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 4)

        bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
        bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
        bufs.avail_out = outBuffer.count

        var patchRes: rs_result = RS_RUNNING

        // Read delta from request body
        for try await buffer in request.body {
            var byteBuffer = buffer
            let nBytes = byteBuffer.readableBytes

            if nBytes > 0 {
                if bufs.avail_in > BUFFER_SIZE {
                    rs_file_close(newFile)
                    rs_file_close(oldFile)
                    rs_job_free(job)
                    throw HTTPError(.internalServerError, message: "Insufficient buffer capacity")
                }

                if bufs.avail_in > 0 {
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                // Copy data from ByteBuffer
                byteBuffer.withUnsafeReadableBytes { bytes in
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memcpy(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), bytes.baseAddress!, nBytes)
                    }
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += nBytes

                logger.debug("Received \(nBytes) bytes of delta")
            }

            // Process data
            while bufs.avail_in > 0 && (patchRes == RS_RUNNING || patchRes == RS_BLOCKED) {
                patchRes = rs_job_iter(job, &bufs)
                if patchRes != RS_DONE && patchRes != RS_BLOCKED {
                    rs_file_close(newFile)
                    rs_file_close(oldFile)
                    rs_job_free(job)
                    throw HTTPError(.internalServerError, message: "Patch failed")
                }

                // Drain output buffer
                let present = outBuffer.withInt8Pointer { baseAddr in
                    guard let nextOut = bufs.next_out else { return 0 }
                    return UnsafePointer(nextOut) - baseAddr
                }
                if present > 0 {
                    let written = fwrite(outBuffer, 1, present, newFile)
                    if written == 0 {
                        rs_file_close(newFile)
                        rs_file_close(oldFile)
                        rs_job_free(job)
                        throw HTTPError(.internalServerError, message: "Failed to write to file")
                    }

                    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_out = outBuffer.count
                }

                if patchRes == RS_DONE {
                    break
                }
            }

            if patchRes == RS_DONE {
                break
            }
        }

        // Mark EOF and finish processing
        bufs.eof_in = 1
        while patchRes == RS_RUNNING || patchRes == RS_BLOCKED {
            patchRes = rs_job_iter(job, &bufs)
            if patchRes != RS_DONE && patchRes != RS_BLOCKED {
                rs_file_close(newFile)
                rs_file_close(oldFile)
                rs_job_free(job)
                throw HTTPError(.internalServerError, message: "Patch failed on final iteration")
            }

            // Drain output buffer
            let present = outBuffer.withInt8Pointer { baseAddr in
                guard let nextOut = bufs.next_out else { return 0 }
                return UnsafePointer(nextOut) - baseAddr
            }
            if present > 0 {
                let written = fwrite(outBuffer, 1, present, newFile)
                if written == 0 {
                    rs_file_close(newFile)
                    rs_file_close(oldFile)
                    rs_job_free(job)
                    throw HTTPError(.internalServerError, message: "Failed to write to file")
                }

                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = outBuffer.count
            }
        }

        rs_file_close(newFile)
        rs_file_close(oldFile)
        rs_job_free(job)

        logger.info("Successfully created \(newFilename)")

        // Atomically rename .new file to original filename
        let renameResult = rename(newFilename, filename)
        if renameResult != 0 {
            throw HTTPError(.internalServerError, message: "Failed to rename file: \(String(cString: strerror(errno)))")
        }

        logger.info("Atomically renamed \(newFilename) to \(filename)")

        return Response(
            status: .ok,
            body: .init(byteBuffer: ByteBuffer(string: "Delta applied successfully. Updated \(filename)"))
        )
    }

    /// Load signature from HTTP request body (no longer used, kept for reference)
    private func receiveSignatureFromBody(_ request: Request) async throws -> OpaquePointer? {
        var signature: OpaquePointer? = nil
        let job = rs_loadsig_begin(&signature)
        guard job != nil else {
            logger.error("Failed to create loadsig job")
            return nil
        }

        defer { rs_job_free(job) }

        var bufs = rs_buffers_t()
        var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)

        bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }

        var res: rs_result = RS_RUNNING

        // Read from request body stream
        for try await buffer in request.body {
            var byteBuffer = buffer
            let nBytes = byteBuffer.readableBytes

            if nBytes > 0 {
                // Handle existing data in buffer
                if bufs.avail_in > 0 {
                    if bufs.avail_in > BUFFER_SIZE {
                        logger.error("Insufficient buffer capacity")
                        return nil
                    }

                    // Move leftover data to front
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                // Copy new data into buffer
                byteBuffer.withUnsafeReadableBytes { bytes in
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memcpy(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), bytes.baseAddress!, nBytes)
                    }
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += nBytes

                logger.debug("Received \(nBytes) bytes from request body")
            }

            // Process data
            while bufs.avail_in > 0 && res == RS_RUNNING {
                res = rs_job_iter(job, &bufs)
                if res != RS_DONE && res != RS_BLOCKED {
                    logger.error("librsync error: \(res)")
                    return nil
                }
            }

            if res == RS_DONE {
                break
            }
        }

        // Mark EOF and finish processing
        bufs.eof_in = 1
        while res == RS_RUNNING || res == RS_BLOCKED {
            res = rs_job_iter(job, &bufs)
            if res != RS_DONE && res != RS_BLOCKED {
                logger.error("librsync error on final iteration: \(res)")
                return nil
            }
        }

        guard let sig = signature else {
            logger.error("Signature is nil after loading")
            return nil
        }

        return sig
    }

    /// Stream delta as HTTP response body
    private func streamDelta(signature: OpaquePointer, filename: String) async throws -> Response {
        // Build hash table
        let res = rs_build_hash_table(signature)
        guard res == RS_DONE else {
            rs_free_sumset(signature)
            throw HTTPError(.internalServerError, message: "Failed to build hash table")
        }

        // Open file
        guard let file = rs_file_open(filename, "rb", 0) else {
            rs_free_sumset(signature)
            throw HTTPError(.internalServerError, message: "Failed to open file")
        }

        // Create response with streamed body
        return Response(
            status: .ok,
            headers: [
                .contentType: "application/octet-stream",
                .transferEncoding: "chunked"
            ],
            body: .init(asyncSequence: DeltaStream(file: file, signature: signature))
        )
    }
}

// MARK: - Signature Streaming

struct SignatureStream: AsyncSequence {
    typealias Element = ByteBuffer

    let file: UnsafeMutablePointer<FILE>
    let job: OpaquePointer

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(file: file, job: job)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let file: UnsafeMutablePointer<FILE>
        let job: OpaquePointer
        var bufs: rs_buffers_t
        var inBuffer: [UInt8]
        var outBuffer: [UInt8]
        var sigRes: rs_result
        var isInitialized = false
        var isDone = false

        init(file: UnsafeMutablePointer<FILE>, job: OpaquePointer) {
            self.file = file
            self.job = job
            self.bufs = rs_buffers_t()
            self.inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
            self.outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
            self.sigRes = RS_RUNNING
        }

        mutating func next() async -> ByteBuffer? {
            // Initialize buffers on first call
            if !isInitialized {
                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = BUFFER_SIZE
                isInitialized = true
            }

            if isDone {
                return nil
            }

            // Fill input buffer if needed
            if bufs.eof_in == 0 {
                if bufs.avail_in >= inBuffer.count {
                    logger.error("Insufficient buffer capacity")
                    cleanup()
                    return nil
                }

                if bufs.avail_in > 0 {
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                // Read from file
                var nBytes: Int = 0
                let bufferSize = inBuffer.count
                inBuffer.withUnsafeMutableBytes { dest in
                    nBytes = fread(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), 1, bufferSize - Int(bufs.avail_in), file)
                }

                logger.debug("Read \(nBytes) bytes from file")

                if nBytes == 0 {
                    if ferror(file) != 0 {
                        logger.error("Failed to read file")
                        cleanup()
                        return nil
                    }
                    bufs.eof_in = feof(file) != 0 ? 1 : 0
                    assert(bufs.eof_in != 0)
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += nBytes
            }

            // Process data
            logger.debug("Running signature job iteration")
            sigRes = rs_job_iter(job, &bufs)
            if sigRes != RS_DONE && sigRes != RS_BLOCKED {
                logger.error("librsync error: \(sigRes)")
                cleanup()
                return nil
            }

            // Check for output
            let present = outBuffer.withInt8Pointer { baseAddr in
                guard let nextOut = bufs.next_out else { return 0 }
                return UnsafePointer(nextOut) - baseAddr
            }

            if present > 0 {
                assert(present <= BUFFER_SIZE)
                logger.debug("Sending \(present) bytes of signature")
                var buffer = ByteBuffer()
                buffer.writeBytes(outBuffer.prefix(present))

                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = BUFFER_SIZE

                return buffer
            }

            // Check if done
            if sigRes == RS_DONE {
                cleanup()
                isDone = true
                return nil
            }

            // No output yet but not done, continue iteration
            return await next()
        }

        mutating func cleanup() {
            rs_file_close(file)
            rs_job_free(job)
        }
    }
}

// MARK: - Delta Streaming (no longer used)

struct DeltaStream: AsyncSequence {
    typealias Element = ByteBuffer

    let file: UnsafeMutablePointer<FILE>
    let signature: OpaquePointer

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(file: file, signature: signature)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let file: UnsafeMutablePointer<FILE>
        let signature: OpaquePointer
        var job: OpaquePointer?
        var bufs: rs_buffers_t
        var inBuffer: [UInt8]
        var outBuffer: [UInt8]
        var deltaRes: rs_result
        var isInitialized = false
        var isDone = false

        init(file: UnsafeMutablePointer<FILE>, signature: OpaquePointer) {
            self.file = file
            self.signature = signature
            self.job = nil
            self.bufs = rs_buffers_t()
            self.inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
            self.outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
            self.deltaRes = RS_RUNNING
        }

        mutating func next() async -> ByteBuffer? {
            // Initialize job on first call
            if !isInitialized {
                job = rs_delta_begin(signature)
                guard job != nil else {
                    cleanup()
                    return nil
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = BUFFER_SIZE
                isInitialized = true
            }

            if isDone {
                return nil
            }

            // Fill input buffer if needed
            if bufs.eof_in == 0 {
                if bufs.avail_in >= inBuffer.count {
                    logger.error("Insufficient buffer capacity")
                    cleanup()
                    return nil
                }

                if bufs.avail_in > 0 {
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                // Read from file
                var nBytes: Int = 0
                let bufferSize = inBuffer.count
                inBuffer.withUnsafeMutableBytes { dest in
                    nBytes = fread(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), 1, bufferSize - Int(bufs.avail_in), file)
                }

                if nBytes == 0 {
                    if ferror(file) != 0 {
                        logger.error("Failed to read file")
                        cleanup()
                        return nil
                    }
                    bufs.eof_in = feof(file) != 0 ? 1 : 0
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += nBytes
            }

            // Process data
            deltaRes = rs_job_iter(job, &bufs)
            if deltaRes != RS_DONE && deltaRes != RS_BLOCKED {
                logger.error("librsync error: \(deltaRes)")
                cleanup()
                return nil
            }

            // Check for output
            let present = outBuffer.withInt8Pointer { baseAddr in
                guard let nextOut = bufs.next_out else { return 0 }
                return UnsafePointer(nextOut) - baseAddr
            }

            if present > 0 {
                var buffer = ByteBuffer()
                buffer.writeBytes(outBuffer.prefix(present))

                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = BUFFER_SIZE

                logger.debug("Streaming \(present) bytes")
                return buffer
            }

            // Check if done
            if deltaRes == RS_DONE {
                cleanup()
                isDone = true
                return nil
            }

            // No output yet but not done, continue iteration
            return await next()
        }

        mutating func cleanup() {
            if let job = job {
                rs_job_free(job)
                self.job = nil
            }
            rs_file_close(file)
            rs_free_sumset(signature)
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
