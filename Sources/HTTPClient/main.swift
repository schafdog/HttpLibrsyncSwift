/*
 * HTTP Client implement librsync 
 *
 * Copyright (C) 2025 by Dennis Schafroth <dennis@schafroth.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 */

import Foundation
import AsyncHTTPClient
import LibrsyncSwift
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

// MARK: - File Upload Stream

/// AsyncSequence for uploading full file content
struct FileUploadStream: AsyncSequence, Sendable {
    typealias Element = ByteBuffer

    let fileURL: URL

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(fileURL: fileURL)
    }

    struct AsyncIterator: AsyncIteratorProtocol {
        let fileURL: URL
        var file: UnsafeMutablePointer<FILE>?
        var isDone = false

        init(fileURL: URL) {
            self.fileURL = fileURL
        }

        mutating func next() async -> ByteBuffer? {
            if !isDone && file == nil {
                guard let f = fopen(fileURL.path, "rb") else {
                    isDone = true
                    return nil
                }
                file = f
            }

            if isDone {
                return nil
            }

            guard let file = file else {
                return nil
            }

            var buffer = [UInt8](repeating: 0, count: 65536)
            let bytesRead = fread(&buffer, 1, 65536, file)

            if bytesRead == 0 {
                fclose(file)
                self.file = nil
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

// MARK: - Error Types

enum RSyncError: Error {
    case fileNotFound
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

        let fileURL = URL(fileURLWithPath: filename)

        // Verify file exists
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.error("File not found: \(filename)")
            exit(EXIT_FAILURE)
        }

        logger.notice("Connecting to server at \(serverURL)")
        logger.info("Processing file: \(filename)")

        // Create HTTP client
        let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)

        // Create librsync wrapper
        let rsync = Librsync()

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

            let uploadURL = "\(serverURL)/upload?file=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)"

            var uploadRequest = HTTPClientRequest(url: uploadURL)
            uploadRequest.method = .POST
            uploadRequest.headers.add(name: "Content-Type", value: "application/octet-stream")
            uploadRequest.headers.add(name: "Transfer-Encoding", value: "chunked")

            // Create file stream
            let fileStream = FileUploadStream(fileURL: fileURL)
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

            // Shutdown HTTP client gracefully
            try await httpClient.shutdown()
            return
        }

        guard signatureResponse.status == .ok else {
            throw RSyncError.httpError("Server returned status: \(signatureResponse.status)")
        }

        // Step 2: Load signature from response using LibrsyncWrapper
        logger.info("Loading signature from server...")

        // Convert response body to AsyncSequence<Data>
        let signatureDataStream = signatureResponse.body.map { buffer in
            Data(buffer.readableBytesView)
        }

        let signatureHandle = try await rsync.loadSignature(from: signatureDataStream)
        logger.info("Signature loaded successfully")

        // Step 3: Generate delta stream from local file using LibrsyncWrapper
        logger.info("Generating delta from local file...")

        let deltaDataStream = rsync.deltaStream(from: fileURL, against: signatureHandle)

        // Convert Data chunks to ByteBuffer for AsyncHTTPClient
        let deltaByteBufferStream = deltaDataStream.map { data in
            var buffer = ByteBuffer()
            buffer.writeBytes(data)
            return buffer
        }

        // Step 4: Send delta to server
        logger.info("Sending delta to server...")

        let deltaURL = "\(serverURL)/delta?file=\(filename.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? filename)"

        var postRequest = HTTPClientRequest(url: deltaURL)
        postRequest.method = .POST
        postRequest.headers.add(name: "Content-Type", value: "application/octet-stream")
        postRequest.headers.add(name: "Transfer-Encoding", value: "chunked")

        // Set body to stream delta
        postRequest.body = .stream(deltaByteBufferStream, length: .unknown)

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

        // Shutdown HTTP client gracefully
        try await httpClient.shutdown()
    }
}
