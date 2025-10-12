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
 * Tests for LibrsyncWrapper
 */

import XCTest
import Foundation
@testable import RsyncSwift

final class LibrsyncWrapperTests: XCTestCase {
    var tempDirectory: URL!
    var rsync: Librsync!

    override func setUp() async throws {
        try await super.setUp()

        // Create temporary directory for test files
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        rsync = Librsync()
    }

    override func tearDown() async throws {
        // Clean up temporary directory
        try? FileManager.default.removeItem(at: tempDirectory)
        try await super.tearDown()
    }

    // MARK: - Helper Methods

    func createTestFile(name: String, content: String) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    func createTestFile(name: String, data: Data) throws -> URL {
        let fileURL = tempDirectory.appendingPathComponent(name)
        try data.write(to: fileURL)
        return fileURL
    }

    func readFile(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Signature Generation Tests

    func testGenerateSignatureFromSmallFile() async throws {
        // Given: A small text file
        let content = "Hello, librsync!"
        let fileURL = try createTestFile(name: "test.txt", content: content)

        // When: Generating signature
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // Then: Signature should be generated
        XCTAssertFalse(signatureData.isEmpty, "Signature should not be empty")
        XCTAssertGreaterThan(signatureData.count, 0, "Signature should have data")
    }

    func testGenerateSignatureFromLargeFile() async throws {
        // Given: A larger file (1MB)
        let largeContent = String(repeating: "This is a test line.\n", count: 50000)
        let fileURL = try createTestFile(name: "large.txt", content: largeContent)

        // When: Generating signature
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // Then: Signature should be generated
        XCTAssertFalse(signatureData.isEmpty)
        XCTAssertGreaterThan(signatureData.count, 0)
    }

    func testGenerateSignatureFromNonExistentFile() async throws {
        // Given: A non-existent file
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.txt")

        // When/Then: Should throw error
        do {
            _ = try await rsync.generateSignature(from: nonExistentURL)
            XCTFail("Should throw error for non-existent file")
        } catch let error as LibrsyncError {
            if case .fileNotFound(let path) = error {
                XCTAssertTrue(path.contains("nonexistent.txt"))
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Signature Streaming Tests

    func testSignatureStreamingProducesChunks() async throws {
        // Given: A file
        let content = String(repeating: "Test data\n", count: 10000)
        let fileURL = try createTestFile(name: "stream_test.txt", content: content)

        // When: Streaming signature
        let stream = rsync.signatureStream(from: fileURL)
        var chunkCount = 0
        var totalBytes = 0

        for try await chunk in stream {
            chunkCount += 1
            totalBytes += chunk.count
        }

        // Then: Should produce multiple chunks
        XCTAssertGreaterThan(chunkCount, 0, "Should produce at least one chunk")
        XCTAssertGreaterThan(totalBytes, 0, "Should produce data")
    }

    // MARK: - Signature Loading Tests

    func testLoadSignatureFromData() async throws {
        // Given: Generate a signature
        let content = "Original file content"
        let fileURL = try createTestFile(name: "original.txt", content: content)
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // When: Loading the signature
        let signatureHandle = try await rsync.loadSignature(from: signatureData)

        // Then: Should load successfully (handle should not be nil)
        XCTAssertNotNil(signatureHandle)
    }

    func testLoadSignatureFromStream() async throws {
        // Given: Generate a signature and create a stream
        let content = "Original file content"
        let fileURL = try createTestFile(name: "original.txt", content: content)
        let signatureData = try await rsync.generateSignature(from: fileURL)

        // Create async stream
        let stream = AsyncStream<Data> { continuation in
            // Split into chunks to test streaming
            let chunkSize = 1024
            var offset = 0
            while offset < signatureData.count {
                let end = min(offset + chunkSize, signatureData.count)
                let chunk = signatureData[offset..<end]
                continuation.yield(Data(chunk))
                offset = end
            }
            continuation.finish()
        }

        // When: Loading from stream
        let signatureHandle = try await rsync.loadSignature(from: stream)

        // Then: Should load successfully
        XCTAssertNotNil(signatureHandle)
    }

    func testLoadInvalidSignature() async throws {
        // Given: Invalid signature data
        let invalidData = Data("This is not a valid signature".utf8)

        // When/Then: Should throw error
        do {
            _ = try await rsync.loadSignature(from: invalidData)
            XCTFail("Should throw error for invalid signature")
        } catch let error as LibrsyncError {
            // Expected to fail
            XCTAssertTrue(error.description.contains("signature") || error.description.contains("load"))
        }
    }

    // MARK: - Delta Generation Tests

    func testGenerateDeltaForIdenticalFiles() async throws {
        // Given: Two identical files
        let content = "Same content in both files"
        let oldFileURL = try createTestFile(name: "old.txt", content: content)
        let newFileURL = try createTestFile(name: "new.txt", content: content)

        // When: Generating delta
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // Then: Delta should be small (files are identical)
        XCTAssertFalse(deltaData.isEmpty, "Delta should not be empty")
        // Delta for identical files is typically very small
        XCTAssertLessThan(deltaData.count, content.count, "Delta should be smaller than original")
    }

    func testGenerateDeltaForModifiedFile() async throws {
        // Given: Original and modified files
        let originalContent = "This is the original content.\nLine 2\nLine 3\n"
        let modifiedContent = "This is the MODIFIED content.\nLine 2\nLine 3\nLine 4\n"

        let oldFileURL = try createTestFile(name: "old.txt", content: originalContent)
        let newFileURL = try createTestFile(name: "new.txt", content: modifiedContent)

        // When: Generating delta
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // Then: Delta should be generated
        XCTAssertFalse(deltaData.isEmpty)
        XCTAssertGreaterThan(deltaData.count, 0)
    }

    func testGenerateDeltaForCompletelyDifferentFiles() async throws {
        // Given: Completely different files
        let oldContent = String(repeating: "A", count: 1000)
        let newContent = String(repeating: "B", count: 1000)

        let oldFileURL = try createTestFile(name: "old.txt", content: oldContent)
        let newFileURL = try createTestFile(name: "new.txt", content: newContent)

        // When: Generating delta
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // Then: Delta should be generated
        XCTAssertFalse(deltaData.isEmpty)
    }

    // MARK: - Delta Streaming Tests

    func testDeltaStreamingProducesChunks() async throws {
        // Given: Two files
        let oldContent = String(repeating: "Original line\n", count: 1000)
        let newContent = String(repeating: "Modified line\n", count: 1000)

        let oldFileURL = try createTestFile(name: "old.txt", content: oldContent)
        let newFileURL = try createTestFile(name: "new.txt", content: newContent)

        // When: Streaming delta generation
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)

        let deltaStream = rsync.deltaStream(from: newFileURL, against: signatureHandle)
        var chunkCount = 0
        var totalBytes = 0

        for try await chunk in deltaStream {
            chunkCount += 1
            totalBytes += chunk.count
        }

        // Then: Should produce chunks
        XCTAssertGreaterThan(chunkCount, 0)
        XCTAssertGreaterThan(totalBytes, 0)
    }

    // MARK: - Patch Application Tests

    func testApplyPatchToRestoreFile() async throws {
        // Given: Original file, modified file, and delta
        let originalContent = "Line 1\nLine 2\nLine 3\n"
        let modifiedContent = "Line 1\nLine 2 MODIFIED\nLine 3\nLine 4\n"

        let oldFileURL = try createTestFile(name: "old.txt", content: originalContent)
        let newFileURL = try createTestFile(name: "new.txt", content: modifiedContent)
        let patchedFileURL = tempDirectory.appendingPathComponent("patched.txt")

        // Generate signature from old file
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)

        // Generate delta from new file
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // When: Applying patch to old file
        try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

        // Then: Patched file should match new file
        let patchedContent = try readFile(patchedFileURL)
        XCTAssertEqual(patchedContent, modifiedContent, "Patched content should match modified content")
    }

    func testApplyPatchWithAtomicRename() async throws {
        // Given: Original file and delta
        let originalContent = "Original content"
        let modifiedContent = "Modified content"

        let oldFileURL = try createTestFile(name: "file.txt", content: originalContent)
        let newFileURL = try createTestFile(name: "new.txt", content: modifiedContent)

        // Generate delta
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        // When: Patching with atomic rename
        try await rsync.patch(oldFileURL, with: deltaData)

        // Then: File should be replaced with patched version
        let finalContent = try readFile(oldFileURL)
        XCTAssertEqual(finalContent, modifiedContent, "File should be updated")
    }

    func testApplyPatchToNonExistentBasisFile() async throws {
        // Given: Non-existent basis file
        let nonExistentURL = tempDirectory.appendingPathComponent("nonexistent.txt")
        let outputURL = tempDirectory.appendingPathComponent("output.txt")
        let deltaData = Data("fake delta".utf8)

        // When/Then: Should throw error
        do {
            try await rsync.applyPatch(delta: deltaData, toBasis: nonExistentURL, output: outputURL)
            XCTFail("Should throw error for non-existent basis file")
        } catch let error as LibrsyncError {
            if case .fileNotFound = error {
                // Expected
            } else {
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Round-Trip Tests

    func testCompleteRoundTripWithSmallFile() async throws {
        // Given: Original and modified files
        let originalContent = "Hello, World!\nThis is line 2.\n"
        let modifiedContent = "Hello, Universe!\nThis is line 2.\nThis is line 3.\n"

        let oldFileURL = try createTestFile(name: "original.txt", content: originalContent)
        let newFileURL = try createTestFile(name: "modified.txt", content: modifiedContent)

        // When: Complete round-trip (signature -> delta -> patch)
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        let patchedFileURL = tempDirectory.appendingPathComponent("patched.txt")
        try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

        // Then: Patched file should match modified file
        let patchedContent = try readFile(patchedFileURL)
        XCTAssertEqual(patchedContent, modifiedContent)
    }

    func testCompleteRoundTripWithBinaryData() async throws {
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

        let oldFileURL = try createTestFile(name: "original.bin", data: originalData)
        let newFileURL = try createTestFile(name: "modified.bin", data: modifiedData)

        // When: Complete round-trip
        let signatureData = try await rsync.generateSignature(from: oldFileURL)
        let signatureHandle = try await rsync.loadSignature(from: signatureData)
        let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

        let patchedFileURL = tempDirectory.appendingPathComponent("patched.bin")
        try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

        // Then: Patched data should match modified data
        let patchedData = try Data(contentsOf: patchedFileURL)
        XCTAssertEqual(patchedData, modifiedData)
    }

    // MARK: - Configuration Tests

    func testCustomConfiguration() async throws {
        // Given: Custom configuration
        let customConfig = LibrsyncConfig(
            bufferSize: 32768,
            blockLength: 1024,
            strongLength: 16
        )
        let customRsync = Librsync(config: customConfig)

        // When: Using custom configuration
        let content = "Test content"
        let fileURL = try createTestFile(name: "test.txt", content: content)
        let signatureData = try await customRsync.generateSignature(from: fileURL)

        // Then: Should work with custom config
        XCTAssertFalse(signatureData.isEmpty)
    }

    // MARK: - Convenience API Tests

    func testDeltaConvenienceMethod() async throws {
        // Given: Two files
        let oldContent = "Old content"
        let newContent = "New content"

        let oldFileURL = try createTestFile(name: "old.txt", content: oldContent)
        let newFileURL = try createTestFile(name: "new.txt", content: newContent)

        // When: Using convenience method
        let deltaData = try await rsync.delta(from: newFileURL, to: oldFileURL)

        // Then: Should generate delta
        XCTAssertFalse(deltaData.isEmpty)
    }

    // MARK: - Error Handling Tests

    func testErrorDescriptions() {
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
            XCTAssertFalse(error.description.isEmpty, "Error description should not be empty")
        }
    }

    // MARK: - Thread Safety Tests

    func testConcurrentSignatureGeneration() async throws {
        // Given: Multiple files
        let files = try (0..<5).map { i in
            try createTestFile(name: "file\(i).txt", content: "Content \(i)")
        }

        // When: Generating signatures concurrently
        try await withThrowingTaskGroup(of: Data.self) { group in
            for fileURL in files {
                group.addTask {
                    try await self.rsync.generateSignature(from: fileURL)
                }
            }

            var signatureCount = 0
            for try await signature in group {
                XCTAssertFalse(signature.isEmpty)
                signatureCount += 1
            }

            // Then: All signatures should be generated
            XCTAssertEqual(signatureCount, files.count)
        }
    }
}
