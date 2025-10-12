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
 * Modern Swift 6.2 wrapper for librsync API with streaming support
 */

import Foundation
import Clibrsync

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - Error Types

/// Errors that can occur during librsync operations
public enum LibrsyncError: Error, CustomStringConvertible, Sendable {
    case fileNotFound(String)
    case fileOpenFailed(String)
    case fileReadError
    case fileWriteError
    case invalidSignature
    case signatureGenerationFailed(rs_result)
    case signatureLoadFailed(rs_result)
    case deltaGenerationFailed(rs_result)
    case patchApplicationFailed(rs_result)
    case hashTableBuildFailed(rs_result)
    case insufficientBuffer
    case jobCreationFailed
    case invalidState

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileOpenFailed(let path):
            return "Failed to open file: \(path)"
        case .fileReadError:
            return "Failed to read from file"
        case .fileWriteError:
            return "Failed to write to file"
        case .invalidSignature:
            return "Invalid signature data"
        case .signatureGenerationFailed(let result):
            return "Signature generation failed with result: \(result)"
        case .signatureLoadFailed(let result):
            return "Signature load failed with result: \(result)"
        case .deltaGenerationFailed(let result):
            return "Delta generation failed with result: \(result)"
        case .patchApplicationFailed(let result):
            return "Patch application failed with result: \(result)"
        case .hashTableBuildFailed(let result):
            return "Hash table build failed with result: \(result)"
        case .insufficientBuffer:
            return "Insufficient buffer capacity"
        case .jobCreationFailed:
            return "Failed to create librsync job"
        case .invalidState:
            return "Invalid operation state"
        }
    }
}

// MARK: - Configuration

/// Configuration for librsync operations
public struct LibrsyncConfig: Sendable {
    /// Buffer size for I/O operations (default: 64KB)
    public let bufferSize: Int

    /// Block length for signature generation (0 = auto)
    public let blockLength: Int

    /// Strong hash length for signature generation (0 = auto)
    public let strongLength: Int

    /// Signature magic number format
    public let signatureMagic: rs_magic_number

    public init(
        bufferSize: Int = 65536,
        blockLength: Int = 0,
        strongLength: Int = 0,
        signatureMagic: rs_magic_number = RS_BLAKE2_SIG_MAGIC
    ) {
        self.bufferSize = bufferSize
        self.blockLength = blockLength
        self.strongLength = strongLength
        self.signatureMagic = signatureMagic
    }

    public static let `default` = LibrsyncConfig()
}

// MARK: - Signature Handle

/// A thread-safe handle to a loaded signature
public final class SignatureHandle: @unchecked Sendable {
    private var signature: OpaquePointer?
    private let lock = NSLock()

    fileprivate init(signature: OpaquePointer) {
        self.signature = signature
    }

    deinit {
        lock.lock()
        defer { lock.unlock() }
        if let sig = signature {
            rs_free_sumset(sig)
            signature = nil
        }
    }

    fileprivate func withSignature<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let sig = signature else {
            fatalError("Signature already freed")
        }
        return try body(sig)
    }
}

// MARK: - Streaming API

/// AsyncSequence that streams signature data from a file
public struct SignatureStream: AsyncSequence, Sendable {
    public typealias Element = Data

    private let fileURL: URL
    private let config: LibrsyncConfig

    public init(fileURL: URL, config: LibrsyncConfig = .default) {
        self.fileURL = fileURL
        self.config = config
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(fileURL: fileURL, config: config)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let fileURL: URL
        private let config: LibrsyncConfig
        private var file: UnsafeMutablePointer<FILE>?
        private var job: OpaquePointer?
        private var bufs: rs_buffers_t
        private var inBuffer: [UInt8]
        private var outBuffer: [UInt8]
        private var result: rs_result
        private var isInitialized = false
        private var isDone = false

        init(fileURL: URL, config: LibrsyncConfig) {
            self.fileURL = fileURL
            self.config = config
            self.bufs = rs_buffers_t()
            self.inBuffer = [UInt8](repeating: 0, count: config.bufferSize)
            self.outBuffer = [UInt8](repeating: 0, count: config.bufferSize)
            self.result = RS_RUNNING
        }

        public mutating func next() async -> Data? {
            if !isInitialized {
                guard let file = rs_file_open(fileURL.path, "rb", 0) else {
                    return nil
                }
                self.file = file

                // Get optimal signature parameters
                let fileSize = rs_file_size(file)
                var sigMagic = config.signatureMagic
                var blockLen = config.blockLength
                var strongLen = config.strongLength

                let argsResult = rs_sig_args(fileSize, &sigMagic, &blockLen, &strongLen)
                guard argsResult == RS_DONE else {
                    cleanup()
                    return nil
                }

                guard let job = rs_sig_begin(blockLen, strongLen, sigMagic) else {
                    cleanup()
                    return nil
                }
                self.job = job

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = config.bufferSize
                isInitialized = true
            }

            if isDone {
                return nil
            }

            guard let file = file, let job = job else {
                return nil
            }

            // Main processing loop
            while true {
                // Read input if needed
                if bufs.eof_in == 0 && bufs.avail_in < config.bufferSize {
                    if bufs.avail_in > 0 {
                        inBuffer.withUnsafeMutableBytes { dest in
                            _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                        }
                    }

                    var nBytes: Int = 0
                    inBuffer.withUnsafeMutableBytes { dest in
                        nBytes = fread(
                            dest.baseAddress!.advanced(by: Int(bufs.avail_in)),
                            1,
                            config.bufferSize - Int(bufs.avail_in),
                            file
                        )
                    }

                    if nBytes == 0 {
                        if ferror(file) != 0 {
                            cleanup()
                            return nil
                        }
                        bufs.eof_in = 1
                    }

                    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_in += nBytes
                }

                // Process data
                result = rs_job_iter(job, &bufs)

                if result != RS_DONE && result != RS_BLOCKED && result != RS_RUNNING {
                    cleanup()
                    return nil
                }

                // Check for output
                let outputSize = outBuffer.withInt8Pointer { baseAddr in
                    guard let nextOut = bufs.next_out else { return 0 }
                    return UnsafePointer(nextOut) - baseAddr
                }

                if outputSize > 0 {
                    let chunk = Data(outBuffer.prefix(outputSize))
                    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_out = config.bufferSize

                    if result == RS_DONE {
                        isDone = true
                        cleanup()
                    }

                    return chunk
                }

                // No output and done
                if result == RS_DONE {
                    cleanup()
                    isDone = true
                    return nil
                }
            }
        }

        private mutating func cleanup() {
            if let job = job {
                rs_job_free(job)
                self.job = nil
            }
            if let file = file {
                rs_file_close(file)
                self.file = nil
            }
        }
    }
}

/// AsyncSequence that streams delta data
public struct DeltaStream: AsyncSequence, Sendable {
    public typealias Element = Data

    private let fileURL: URL
    private let signatureHandle: SignatureHandle
    private let config: LibrsyncConfig

    public init(fileURL: URL, signatureHandle: SignatureHandle, config: LibrsyncConfig = .default) {
        self.fileURL = fileURL
        self.signatureHandle = signatureHandle
        self.config = config
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(fileURL: fileURL, signatureHandle: signatureHandle, config: config)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private let fileURL: URL
        private let signatureHandle: SignatureHandle
        private let config: LibrsyncConfig
        private var file: UnsafeMutablePointer<FILE>?
        private var job: OpaquePointer?
        private var bufs: rs_buffers_t
        private var inBuffer: [UInt8]
        private var outBuffer: [UInt8]
        private var result: rs_result
        private var isInitialized = false
        private var isDone = false

        init(fileURL: URL, signatureHandle: SignatureHandle, config: LibrsyncConfig) {
            self.fileURL = fileURL
            self.signatureHandle = signatureHandle
            self.config = config
            self.bufs = rs_buffers_t()
            self.inBuffer = [UInt8](repeating: 0, count: config.bufferSize * 2)
            self.outBuffer = [UInt8](repeating: 0, count: config.bufferSize * 2)
            self.result = RS_RUNNING
        }

        public mutating func next() async -> Data? {
            if !isInitialized {
                guard let file = rs_file_open(fileURL.path, "rb", 0) else {
                    return nil
                }
                self.file = file

                // Build hash table and create delta job
                let job: OpaquePointer? = signatureHandle.withSignature { signature in
                    let hashResult = rs_build_hash_table(signature)
                    guard hashResult == RS_DONE else {
                        return nil
                    }
                    return rs_delta_begin(signature)
                }

                guard let deltaJob = job else {
                    cleanup()
                    return nil
                }
                self.job = deltaJob

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = config.bufferSize
                isInitialized = true
            }

            if isDone {
                return nil
            }

            guard let file = file, let job = job else {
                return nil
            }

            // Main processing loop
            while true {
                // Read input if needed
                if bufs.eof_in == 0 {
                    if bufs.avail_in > 0 {
                        inBuffer.withUnsafeMutableBytes { dest in
                            _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                        }
                    }

                    var nBytes: Int = 0
                    inBuffer.withUnsafeMutableBytes { dest in
                        nBytes = fread(
                            dest.baseAddress!.advanced(by: Int(bufs.avail_in)),
                            1,
                            inBuffer.count - Int(bufs.avail_in),
                            file
                        )
                    }

                    if nBytes == 0 {
                        if ferror(file) != 0 {
                            cleanup()
                            return nil
                        }
                        bufs.eof_in = 1
                    }

                    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_in += nBytes
                }

                // Process data - may need multiple iterations
                var iterations = 0
                while (result == RS_RUNNING || result == RS_BLOCKED) && iterations < 1000 {
                    result = rs_job_iter(job, &bufs)
                    iterations += 1

                    if result != RS_DONE && result != RS_BLOCKED && result != RS_RUNNING {
                        cleanup()
                        return nil
                    }

                    if result == RS_DONE {
                        break
                    }
                }

                // Check for output
                let outputSize = outBuffer.withInt8Pointer { baseAddr in
                    guard let nextOut = bufs.next_out else { return 0 }
                    return UnsafePointer(nextOut) - baseAddr
                }

                if outputSize > 0 {
                    let chunk = Data(outBuffer.prefix(outputSize))
                    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                    bufs.avail_out = config.bufferSize

                    if result == RS_DONE {
                        isDone = true
                        cleanup()
                    }

                    return chunk
                }

                // No output and done
                if result == RS_DONE {
                    cleanup()
                    isDone = true
                    return nil
                }

                // Safety check
                if iterations >= 1000 {
                    cleanup()
                    isDone = true
                    return nil
                }
            }
        }

        private mutating func cleanup() {
            if let job = job {
                rs_job_free(job)
                self.job = nil
            }
            if let file = file {
                rs_file_close(file)
                self.file = nil
            }
        }
    }
}

// MARK: - Main Librsync API

/// Modern Swift wrapper for librsync operations
public struct Librsync: Sendable {
    public let config: LibrsyncConfig

    public init(config: LibrsyncConfig = .default) {
        self.config = config
    }

    // MARK: - Streaming API (Primary)

    /// Stream signature data from a file
    /// - Parameter fileURL: URL of the file to generate signature from
    /// - Returns: AsyncSequence of signature data chunks
    public func signatureStream(from fileURL: URL) -> SignatureStream {
        SignatureStream(fileURL: fileURL, config: config)
    }

    /// Stream delta data between a file and a signature
    /// - Parameters:
    ///   - fileURL: URL of the new file
    ///   - signatureHandle: Handle to the loaded signature of the old file
    /// - Returns: AsyncSequence of delta data chunks
    public func deltaStream(from fileURL: URL, against signatureHandle: SignatureHandle) -> DeltaStream {
        DeltaStream(fileURL: fileURL, signatureHandle: signatureHandle, config: config)
    }

    // MARK: - Signature Loading

    /// Load a signature from streaming data
    /// - Parameter dataStream: AsyncSequence of signature data chunks
    /// - Returns: Handle to the loaded signature
    public func loadSignature<S: AsyncSequence>(from dataStream: S) async throws -> SignatureHandle where S.Element == Data {
        var signature: OpaquePointer? = nil

        guard let job = rs_loadsig_begin(&signature) else {
            throw LibrsyncError.jobCreationFailed
        }

        defer { rs_job_free(job) }

        var bufs = rs_buffers_t()
        var inBuffer = [UInt8](repeating: 0, count: config.bufferSize * 4)

        var result: rs_result = RS_RUNNING

        for try await chunk in dataStream {
            let chunkBytes = [UInt8](chunk)
            var offset = 0

            while offset < chunkBytes.count && (result == RS_RUNNING || result == RS_BLOCKED) {
                // Move remaining data to start
                if bufs.avail_in > 0 {
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                // Copy new data
                let spaceAvailable = inBuffer.count - Int(bufs.avail_in)
                let bytesToCopy = min(spaceAvailable, chunkBytes.count - offset)

                chunkBytes.withUnsafeBytes { src in
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memcpy(
                            dest.baseAddress!.advanced(by: Int(bufs.avail_in)),
                            src.baseAddress!.advanced(by: offset),
                            bytesToCopy
                        )
                    }
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += bytesToCopy
                offset += bytesToCopy

                // Process all available data
                while bufs.avail_in > 0 && (result == RS_RUNNING || result == RS_BLOCKED) {
                    let availBefore = bufs.avail_in
                    result = rs_job_iter(job, &bufs)

                    if result != RS_DONE && result != RS_BLOCKED && result != RS_RUNNING {
                        throw LibrsyncError.signatureLoadFailed(result)
                    }

                    // If no data consumed, need more input
                    if bufs.avail_in == availBefore {
                        break
                    }
                }
            }
        }

        // Mark EOF and finish processing
        bufs.eof_in = 1
        while result == RS_RUNNING || result == RS_BLOCKED {
            result = rs_job_iter(job, &bufs)
            if result != RS_DONE && result != RS_BLOCKED {
                throw LibrsyncError.signatureLoadFailed(result)
            }
        }

        guard let sig = signature else {
            throw LibrsyncError.invalidSignature
        }

        return SignatureHandle(signature: sig)
    }

    /// Load a signature from in-memory data
    /// - Parameter data: Signature data
    /// - Returns: Handle to the loaded signature
    public func loadSignature(from data: Data) async throws -> SignatureHandle {
        // Create single-element async sequence
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        return try await loadSignature(from: stream)
    }

    // MARK: - In-Memory Convenience API

    /// Generate signature and collect all data into memory
    /// - Parameter fileURL: URL of the file to generate signature from
    /// - Returns: Complete signature data
    public func generateSignature(from fileURL: URL) async throws -> Data {
        var result = Data()
        for try await chunk in signatureStream(from: fileURL) {
            result.append(chunk)
        }
        return result
    }

    /// Generate delta and collect all data into memory
    /// - Parameters:
    ///   - fileURL: URL of the new file
    ///   - signatureHandle: Handle to the loaded signature of the old file
    /// - Returns: Complete delta data
    public func generateDelta(from fileURL: URL, against signatureHandle: SignatureHandle) async throws -> Data {
        var result = Data()
        for try await chunk in deltaStream(from: fileURL, against: signatureHandle) {
            result.append(chunk)
        }
        return result
    }

    /// Apply a delta patch to a basis file
    /// - Parameters:
    ///   - deltaData: The delta data
    ///   - basisFileURL: URL of the basis (old) file
    ///   - outputFileURL: URL where the patched file should be written
    public func applyPatch(delta deltaData: Data, toBasis basisFileURL: URL, output outputFileURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: basisFileURL.path) else {
            throw LibrsyncError.fileNotFound(basisFileURL.path)
        }

        guard let basisFile = rs_file_open(basisFileURL.path, "rb", 0) else {
            throw LibrsyncError.fileOpenFailed(basisFileURL.path)
        }
        defer { rs_file_close(basisFile) }

        guard let outputFile = rs_file_open(outputFileURL.path, "wb", 1) else {
            throw LibrsyncError.fileOpenFailed(outputFileURL.path)
        }
        defer { rs_file_close(outputFile) }

        guard let job = rs_patch_begin(rs_file_copy_cb, basisFile) else {
            throw LibrsyncError.jobCreationFailed
        }
        defer { rs_job_free(job) }

        var bufs = rs_buffers_t()
        var inBuffer = [UInt8](repeating: 0, count: config.bufferSize * 2)
        var outBuffer = [UInt8](repeating: 0, count: config.bufferSize * 4)

        bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
        bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
        bufs.avail_out = outBuffer.count

        let deltaBytes = [UInt8](deltaData)
        var offset = 0
        var result: rs_result = RS_RUNNING

        while result == RS_RUNNING || result == RS_BLOCKED {
            // Fill input buffer
            if bufs.avail_in < inBuffer.count / 2 && offset < deltaBytes.count {
                if bufs.avail_in > 0 {
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                    }
                }

                let chunkSize = min(inBuffer.count - Int(bufs.avail_in), deltaBytes.count - offset)
                deltaBytes.withUnsafeBytes { src in
                    inBuffer.withUnsafeMutableBytes { dest in
                        _ = memcpy(
                            dest.baseAddress!.advanced(by: Int(bufs.avail_in)),
                            src.baseAddress!.advanced(by: offset),
                            chunkSize
                        )
                    }
                }

                bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_in += chunkSize
                offset += chunkSize

                if offset >= deltaBytes.count {
                    bufs.eof_in = 1
                }
            }

            // Process data
            result = rs_job_iter(job, &bufs)

            if result != RS_DONE && result != RS_BLOCKED && result != RS_RUNNING {
                throw LibrsyncError.patchApplicationFailed(result)
            }

            // Write output
            let outputSize = outBuffer.withInt8Pointer { baseAddr in
                guard let nextOut = bufs.next_out else { return 0 }
                return UnsafePointer(nextOut) - baseAddr
            }

            if outputSize > 0 {
                let written = fwrite(outBuffer, 1, outputSize, outputFile)
                if written != outputSize {
                    throw LibrsyncError.fileWriteError
                }

                bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
                bufs.avail_out = outBuffer.count
            }
        }
    }

    /// Apply patch and atomically replace original file
    /// - Parameters:
    ///   - deltaData: The delta data
    ///   - fileURL: URL of the file to patch (will be replaced)
    public func patch(_ fileURL: URL, with deltaData: Data) async throws {
        let tempURL = fileURL.appendingPathExtension("new")

        try await applyPatch(delta: deltaData, toBasis: fileURL, output: tempURL)

        // Atomic rename
        let result = rename(tempURL.path, fileURL.path)
        if result != 0 {
            throw LibrsyncError.fileWriteError
        }
    }
}

// MARK: - Convenience Extensions

extension Librsync {
    /// Generate delta between two files (in-memory)
    /// - Parameters:
    ///   - newFileURL: The new/modified file
    ///   - oldFileURL: The old/original file
    /// - Returns: Complete delta data
    public func delta(from newFileURL: URL, to oldFileURL: URL) async throws -> Data {
        let signatureData = try await generateSignature(from: oldFileURL)
        let signatureHandle = try await loadSignature(from: signatureData)
        return try await generateDelta(from: newFileURL, against: signatureHandle)
    }
}
