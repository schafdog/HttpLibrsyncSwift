/*
 * LibrsyncSwift -- the library for network deltas
 *
 * Copyright (C) 2025 by Dennis Schafroth <dennis@schafroth.com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation; either version 2.1 of the License, or
 * (at your option) any later version.
 *
 * Swift Testing framework tests for LibrsyncSwift
 */

import Testing
import Foundation
@testable import LibrsyncSwift

@Suite("LibrsyncSwift Basic Tests")
struct LibrsyncSwiftTests {

    // MARK: - Helper Methods

    func createTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".txt")
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Schedule cleanup
        withKnownIssue {
            try? FileManager.default.removeItem(at: fileURL)
        }

        return fileURL
    }

    func createTempFile(data: Data) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: fileURL)

        // Schedule cleanup
        withKnownIssue {
            try? FileManager.default.removeItem(at: fileURL)
        }

        return fileURL
    }

    // MARK: - Signature Generation Tests

    @Test("Generate signature from small file")
    func generateSignatureFromSmallFile() async throws {
        // Given: A small text file
        let content = "Hello, librsync!"
        let fileURL = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // When: Generating signature
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // Then: Signature should be generated
        #expect(!signatureData.isEmpty, "Signature should not be empty")
        #expect(signatureData.count > 0, "Signature should have data")
    }

    @Test("Generate signature from larger file")
    func generateSignatureFromLargeFile() async throws {
        // Given: A larger file (~1MB)
        let largeContent = String(repeating: "This is a test line.\n", count: 50000)
        let fileURL = try createTempFile(content: largeContent)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // When: Generating signature
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // Then: Signature should be generated
        #expect(!signatureData.isEmpty)
        #expect(signatureData.count > 0)
    }

    //@Test("Generate signature from non-existent file throws error")
    func generateSignatureFromNonExistentFile() async throws {
        // Given: A non-existent file
        let tempDir = FileManager.default.temporaryDirectory
        let nonExistentURL = tempDir.appendingPathComponent("nonexistent_\(UUID().uuidString).txt")

        // When/Then: Should throw error
        let rsync = Librsync()
        await #expect(throws: LibrsyncError.self) {
            try await rsync.generateSignature(from: nonExistentURL)
        }
    }

    // MARK: - Signature Streaming Tests

    @Test("Signature streaming produces chunks")
    func signatureStreamingProducesChunks() async throws {
        // Given: A file
        let content = String(repeating: "Test data\n", count: 10000)
        let fileURL = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // When: Streaming signature
        let rsync = Librsync()
        let stream = rsync.signatureStream(from: fileURL)
        var chunkCount = 0
        var totalBytes = 0

        for try await chunk in stream {
            chunkCount += 1
            totalBytes += chunk.count
        }

        // Then: Should produce chunks
        #expect(chunkCount > 0, "Should produce at least one chunk")
        #expect(totalBytes > 0, "Should produce data")
    }

    // MARK: - Delta Generation Tests

    @Test("Generate delta for identical files")
    func generateDeltaForIdenticalFiles() async throws {
        // Given: Two identical files
        let content = "Same content in both files"
        let oldFileURL = try createTempFile(content: content)
        let newFileURL = try createTempFile(content: content)
        defer {
            try? FileManager.default.removeItem(at: oldFileURL)
            try? FileManager.default.removeItem(at: newFileURL)
        }

        // When: Generating delta
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // Then: Delta should be small (files are identical)
        #expect(!deltaData.isEmpty, "Delta should not be empty")
        #expect(deltaData.count < content.count, "Delta should be smaller than original")
    }

    @Test("Generate delta for modified file")
    func generateDeltaForModifiedFile() async throws {
        // Given: Original and modified files
        let originalContent = "This is the original content.\nLine 2\nLine 3\n"
        let modifiedContent = "This is the MODIFIED content.\nLine 2\nLine 3\nLine 4\n"

        let oldFileURL = try createTempFile(content: originalContent)
        let newFileURL = try createTempFile(content: modifiedContent)
        defer {
            try? FileManager.default.removeItem(at: oldFileURL)
            try? FileManager.default.removeItem(at: newFileURL)
        }

        // When: Generating delta
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // Then: Delta should be generated
        #expect(!deltaData.isEmpty)
        #expect(deltaData.count > 0)
    }

    // MARK: - Round-Trip Tests

    @Test("Complete round-trip with small file")
    func completeRoundTripWithSmallFile() async throws {
        // Given: Original and modified files
        let originalContent = "Hello, World!\nThis is line 2.\n"
        let modifiedContent = "Hello, Universe!\nThis is line 2.\nThis is line 3.\n"

        let oldFileURL = try createTempFile(content: originalContent)
        let newFileURL = try createTempFile(content: modifiedContent)
        let patchedFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_patched.txt")

        defer {
            try? FileManager.default.removeItem(at: oldFileURL)
            try? FileManager.default.removeItem(at: newFileURL)
            try? FileManager.default.removeItem(at: patchedFileURL)
        }

        // When: Complete round-trip (signature -> delta -> patch)
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

        // Then: Patched file should match modified file
        let patchedContent = try String(contentsOf: patchedFileURL, encoding: .utf8)
        #expect(patchedContent == modifiedContent, "Patched content should match modified content")
    }

    @Test("Complete round-trip with binary data")
    func completeRoundTripWithBinaryData() async throws {
        // Given: Binary data files
        var originalData = Data(count: 10000)
        for i in 0..<10000 {
            originalData[i] = UInt8(i % 256)
        }

        var modifiedData = originalData
        // Modify some bytes
        for i in stride(from: 0, to: 10000, by: 100) {
            modifiedData[i] = UInt8((i + 1) % 256)
        }

        let oldFileURL = try createTempFile(data: originalData)
        let newFileURL = try createTempFile(data: modifiedData)
        let patchedFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "_patched.bin")

        defer {
            try? FileManager.default.removeItem(at: oldFileURL)
            try? FileManager.default.removeItem(at: newFileURL)
            try? FileManager.default.removeItem(at: patchedFileURL)
        }

        // When: Complete round-trip
        let rsync = Librsync()
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

        // Then: Patched data should match modified data
        let patchedData = try Data(contentsOf: patchedFileURL)
        #expect(patchedData == modifiedData, "Patched data should match modified data")
    }

    // MARK: - Configuration Tests

    @Test("Custom configuration works")
    func customConfiguration() async throws {
        // Given: Custom configuration
        let customConfig = LibrsyncConfig(
            bufferSize: 32768,
            blockLength: 1024,
            strongLength: 16
        )
        let customRsync = Librsync(config: customConfig)

        // When: Using custom configuration
        let content = "Test content with custom config"
        let fileURL = try createTempFile(content: content)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let signatureData = try await customRsync.generateSignature(from: fileURL)

        // Then: Should work with custom config
        #expect(!signatureData.isEmpty)
    }

    // MARK: - Error Handling Tests

    @Test("Error descriptions are meaningful")
    func errorDescriptions() {
        let errors: [LibrsyncError] = [
            .fileNotFound("/path/to/file"),
            .fileOpenFailed("/path/to/file"),
            .fileReadError,
            .fileWriteError,
            .invalidSignature,
            .insufficientBuffer,
            .jobCreationFailed,
            .invalidState
        ]

        for error in errors {
            #expect(!error.description.isEmpty, "Error description should not be empty: \(error)")
        }
    }

    // MARK: - Thread Safety Tests

    @Test("Concurrent signature generation")
    func concurrentSignatureGeneration() async throws {
        // Given: Multiple files
        var files: [URL] = []
        for i in 0..<5 {
            let fileURL = try createTempFile(content: "Content \(i)")
            files.append(fileURL)
        }

        defer {
            for fileURL in files {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        // When: Generating signatures concurrently
        let rsync = Librsync()

        try await withThrowingTaskGroup(of: Data.self) { group in
            for fileURL in files {
                group.addTask {
                    try await rsync.generateSignature(from: fileURL)
                }
            }

            var signatureCount = 0
            for try await signature in group {
                #expect(!signature.isEmpty)
                signatureCount += 1
            }

            // Then: All signatures should be generated
            #expect(signatureCount == files.count)
        }
    }
}
