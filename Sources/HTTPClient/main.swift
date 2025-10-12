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
 * Converted to Swift with AsyncHTTPClient by Claude Code
 */

import Foundation
import AsyncHTTPClient
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

var logger = Logger(label: "com.rsyncswift.httpclient")

// MARK: - Signature Loading

func receiveSignatureFromResponse(response: HTTPClientResponse) async throws -> OpaquePointer {
    var signature: OpaquePointer? = nil
    let job = rs_loadsig_begin(&signature)
    guard job != nil else {
        throw RSyncError.signatureLoadFailed
    }

    defer { rs_job_free(job) }

    var bufs = rs_buffers_t()
    var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 4)  // Larger buffer for signatures

    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }

    var res: rs_result = RS_RUNNING
    var totalReceived = 0
    var lastLoggedMB = 0

    // Read signature from response body
    for try await var buffer in response.body {
        let nBytes = buffer.readableBytes

        if nBytes > 0 {
            // Ensure we have space in the buffer
            let spaceAvailable = inBuffer.count - Int(bufs.avail_in)
            if nBytes > spaceAvailable {
                logger.error("Incoming chunk (\(nBytes) bytes) larger than available buffer space (\(spaceAvailable) bytes)")
                logger.error("Current buffer state: avail_in=\(bufs.avail_in), buffer size=\(inBuffer.count)")
                throw RSyncError.insufficientBuffer
            }

            if bufs.avail_in > 0 {
                // Move leftover data to front
                inBuffer.withUnsafeMutableBytes { dest in
                    _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                }
            }

            // Copy data from ByteBuffer
            buffer.withUnsafeReadableBytes { bytes in
                inBuffer.withUnsafeMutableBytes { dest in
                    _ = memcpy(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), bytes.baseAddress!, nBytes)
                }
            }

            bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_in += nBytes
            totalReceived += nBytes

            // Log every 10 MB
            let currentMB = totalReceived / (1024 * 1024)
            if currentMB > 0 && currentMB != lastLoggedMB && currentMB % 10 == 0 {
                logger.info("Received \(currentMB) MB of signature data...")
                lastLoggedMB = currentMB
            }
        }

        // Process all available data before reading more
        // RS_BLOCKED is normal - it means "processed what I can, give me more or call again"
        while bufs.avail_in > 0 && (res == RS_RUNNING || res == RS_BLOCKED) {
            let availBefore = bufs.avail_in
            res = rs_job_iter(job, &bufs)
            let consumed = availBefore - bufs.avail_in

            if res != RS_DONE && res != RS_BLOCKED && res != RS_RUNNING {
                logger.error("librsync error during signature load: \(res)")
                throw RSyncError.signatureLoadFailed
            }

            // If librsync isn't consuming data, we need to give it more input
            if consumed == 0 {
                // No more data consumed, need more input from network
                break
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
            throw RSyncError.signatureLoadFailed
        }
    }

    guard let sig = signature else {
        throw RSyncError.signatureLoadFailed
    }

    logger.info("Signature loaded successfully (total: \(totalReceived / (1024*1024)) MB)")
    return sig
}

// MARK: - File Upload Stream

/// AsyncSequence for uploading full file content
struct FileUploadStream: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let file: UnsafeMutablePointer<FILE>

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(file: file)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let file: UnsafeMutablePointer<FILE>
        var isDone = false

        init(file: UnsafeMutablePointer<FILE>) {
            self.file = file
        }

        mutating func next() async -> ByteBuffer? {
            if isDone {
                return nil
            }

            var buffer = [UInt8](repeating: 0, count: BUFFER_SIZE)
            let bytesRead = fread(&buffer, 1, BUFFER_SIZE, file)

            if bytesRead == 0 {
                fclose(file)
                isDone = true
                return nil
            }

            logger.info("Sending \(bytesRead) bytes of file")
            var byteBuffer = ByteBuffer()
            byteBuffer.writeBytes(buffer.prefix(bytesRead))
            return byteBuffer
        }
    }
}

// MARK: - Delta Generation

/// AsyncSequence that generates delta chunks
struct DeltaStream: AsyncSequence, Sendable {
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
                logger.debug("Initializing delta generation...")
                // Build hash table
                let res = rs_build_hash_table(signature)
                guard res == RS_DONE else {
                    logger.error("Failed to build hash table")
                    cleanup()
                    return nil
                }

                job = rs_delta_begin(signature)
                guard job != nil else {
                    logger.error("Failed to create delta job")
                    cleanup()
                    return nil
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = BUFFER_SIZE
                isInitialized = true
                logger.debug("Delta generation initialized")
            }

            if isDone {
                return nil
            }

            // Main loop to avoid tail recursion
            while true {
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
                        if bufs.eof_in != 0 {
                            logger.info("Reached end of input file")
                        }
                    } else {
                        logger.debug("Read \(nBytes) bytes from file for delta generation")
                    }

                    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_in += nBytes
                }

                // Process data - keep calling until we get output or are truly blocked
                var iterations = 0
                while (deltaRes == RS_RUNNING || deltaRes == RS_BLOCKED) && iterations < 1000 {
                    let availInBefore = bufs.avail_in
                    let availOutBefore = bufs.avail_out

                    deltaRes = rs_job_iter(job, &bufs)
                    iterations += 1

                    let consumedIn = availInBefore - bufs.avail_in
                    let producedOut = availOutBefore - bufs.avail_out

                    if iterations % 100 == 0 {
                        logger.debug("Delta iteration \(iterations): consumed=\(consumedIn), produced=\(producedOut), state=\(deltaRes), avail_in=\(bufs.avail_in), avail_out=\(bufs.avail_out)")
                    }

                    if deltaRes != RS_DONE && deltaRes != RS_BLOCKED && deltaRes != RS_RUNNING {
                        logger.error("librsync error: \(deltaRes)")
                        cleanup()
                        return nil
                    }

                    // If blocked and no input/output activity, break to read more from file
                    if deltaRes == RS_BLOCKED && consumedIn == 0 && producedOut == 0 {
                        break
                    }

                    // If we're done, exit the loop but check for remaining output below
                    if deltaRes == RS_DONE {
                        logger.debug("Delta generation complete (RS_DONE)")
                        break
                    }
                }

                // Check for any remaining output in the buffer
                let present = outBuffer.withInt8Pointer { baseAddr in
                    guard let nextOut = bufs.next_out else { return 0 }
                    return UnsafePointer(nextOut) - baseAddr
                }

                if present > 0 {
                    logger.info("Sending \(present) bytes of delta (after \(iterations) iterations)")
                    var buffer = ByteBuffer()
                    buffer.writeBytes(outBuffer.prefix(present))

                    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_out = BUFFER_SIZE

                    // If we're done, mark for cleanup on next call
                    if deltaRes == RS_DONE {
                        isDone = true
                        cleanup()
                    }

                    return buffer
                }

                // No output and we're done - cleanup and signal end
                if deltaRes == RS_DONE {
                    cleanup()
                    isDone = true
                    return nil
                }

                if iterations >= 1000 {
                    logger.warning("Too many iterations (\(iterations)), bailing out")
                    cleanup()
                    isDone = true
                    return nil
                }

                // No output yet but not done, continue the main loop (replaces tail recursion)
            }
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

// MARK: - Error Types

enum RSyncError: Error {
    case fileOpenFailed
    case signatureLoadFailed
    case deltaGenerationFailed
    case insufficientBuffer
    case httpError(String)
}

// MARK: - Main Application

@main
struct HTTPClientApp {
    static func main() async throws {
        // Parse arguments
        var args = CommandLine.arguments

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

        guard args.count >= 3 else {
            print("USAGE: \(args[0]) [OPTIONS] <FILENAME> <SERVER_URL>")
            print("Example: \(args[0]) README.md http://127.0.0.1:8081")
            print("")
            print("OPTIONS:")
            print("  -v, --verbose    Show progress updates (info level)")
            print("  -vv, --debug     Show detailed debugging information (debug level)")
            exit(EXIT_FAILURE)
        }

        let filename = args[1]
        let serverURL = args[2]

        // Verify file exists
        guard FileManager.default.fileExists(atPath: filename) else {
            logger.error("File not found: \(filename)")
            exit(EXIT_FAILURE)
        }

        logger.notice("Connecting to server at \(serverURL)")
        logger.info("Processing file: \(filename)")

        // Create HTTP client
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
        defer {
            try? httpClient.syncShutdown()
        }

        // Step 1: Request signature from server
        let signatureURL = "\(serverURL)/signature?file=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)"
        logger.info("Requesting signature from server...")

        var getRequest = HTTPClientRequest(url: signatureURL)
        getRequest.method = .GET

        // Longer timeout for signature generation on large files
        let signatureResponse = try await httpClient.execute(getRequest, timeout: .minutes(30))

        if signatureResponse.status == .notFound {
            // Server doesn't have the file, upload full file instead
            logger.info("Server doesn't have the file. Uploading full file...")

            guard let file = fopen(filename, "rb") else {
                throw RSyncError.fileOpenFailed
            }

            let uploadURL = "\(serverURL)/upload?file=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)"

            var uploadRequest = HTTPClientRequest(url: uploadURL)
            uploadRequest.method = .POST
            uploadRequest.headers.add(name: "Content-Type", value: "application/octet-stream")
            uploadRequest.headers.add(name: "Transfer-Encoding", value: "chunked")

            // Create file stream
            let fileStream = FileUploadStream(file: file)
            uploadRequest.body = .stream(fileStream, length: .unknown)

            // Use a very long timeout for large file uploads (10 hours)
            let uploadResponse = try await httpClient.execute(uploadRequest, timeout: .hours(10))

            guard uploadResponse.status == .ok else {
                throw RSyncError.httpError("Upload failed with status: \(uploadResponse.status)")
            }

            var responseBody = try await uploadResponse.body.collect(upTo: 1024)
            if let responseMessage = responseBody.readString(length: responseBody.readableBytes) {
                logger.info("Server response: \(responseMessage)")
            }

            logger.notice("Success! Full file uploaded to server.")
            return
        }

        guard signatureResponse.status == .ok else {
            throw RSyncError.httpError("Server returned status: \(signatureResponse.status)")
        }

        // Step 2: Load signature from response
        logger.info("Loading signature from server...")
        let signature = try await receiveSignatureFromResponse(response: signatureResponse)
        logger.info("Signature loaded successfully")

        // Step 3: Generate delta from local file
        logger.info("Generating delta from local file...")

        guard let file = rs_file_open(filename, "rb", 0) else {
            throw RSyncError.fileOpenFailed
        }

        let deltaStream = DeltaStream(file: file, signature: signature)

        // Step 4: Send delta to server
        logger.info("Sending delta to server...")

        let deltaURL = "\(serverURL)/delta?file=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)"

        var postRequest = HTTPClientRequest(url: deltaURL)
        postRequest.method = .POST
        postRequest.headers.add(name: "Content-Type", value: "application/octet-stream")
        postRequest.headers.add(name: "Transfer-Encoding", value: "chunked")

        // Set body to stream delta
        postRequest.body = .stream(deltaStream, length: .unknown)

        // Execute request with long timeout for large deltas
        let deltaResponse = try await httpClient.execute(postRequest, timeout: .hours(10))

        guard deltaResponse.status == .ok else {
            throw RSyncError.httpError("Server returned status: \(deltaResponse.status)")
        }

        // Read response message
        var responseBody = try await deltaResponse.body.collect(upTo: 1024)
        if let responseMessage = responseBody.readString(length: responseBody.readableBytes) {
            logger.info("Server response: \(responseMessage)")
        }

        logger.notice("Success! Delta uploaded to server.")
    }
}
