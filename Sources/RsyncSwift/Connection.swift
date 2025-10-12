import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - Buffer Extensions

extension Array where Element == UInt8 {
    /// Get a mutable Int8 pointer to the array's buffer
    /// WARNING: Only valid while the array remains in scope and unmodified
    public mutating func withMutableInt8Pointer<R>(_ body: (UnsafeMutablePointer<Int8>) -> R) -> R {
        return withUnsafeMutableBytes { buffer in
            body(buffer.baseAddress!.assumingMemoryBound(to: Int8.self))
        }
    }

    /// Get an immutable Int8 pointer to the array's buffer
    public func withInt8Pointer<R>(_ body: (UnsafePointer<Int8>) -> R) -> R {
        return withUnsafeBytes { buffer in
            body(buffer.baseAddress!.assumingMemoryBound(to: Int8.self))
        }
    }
}

// MARK: - Constants
public let PORT: UInt16 = 5612
public let BUFFER_SIZE = 16 * 4096
public let CHUNK_SIZE = BUFFER_SIZE

/// Connection error types
public enum ConnectionError: Error {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    case acceptFailed
    case connectFailed
    case invalidAddress
    case sendFailed
    case receiveFailed
    case headerParseFailed
    case insufficientBuffer
}

/// Write a chunk using chunked transfer encoding
public func writeChunk(socket: Int32, buffer: Data) throws {
    let size = buffer.count
    let header = String(format: "%zx\r\n", size)

    guard let headerData = header.data(using: .utf8) else {
        throw ConnectionError.sendFailed
    }

    // Send header
    let headerBytes = [UInt8](headerData)
    let headerSent = send(socket, headerBytes, headerBytes.count, 0)
    if headerSent == -1 {
        throw ConnectionError.sendFailed
    }

    // Send data
    if size > 0 {
        let dataBytes = [UInt8](buffer)
        let dataSent = send(socket, dataBytes, size, 0)
        if dataSent == -1 {
            throw ConnectionError.sendFailed
        }
    }

    // Send delimiter
    let delimiter = "\r\n".data(using: .utf8)!
    let delimiterBytes = [UInt8](delimiter)
    let delimiterSent = send(socket, delimiterBytes, 2, 0)
    if delimiterSent == -1 {
        throw ConnectionError.sendFailed
    }

    print("Chunk \(size) sent.")
}

/// Read a chunk using chunked transfer encoding
public func readChunk(socket: Int32) throws -> Data {
    var headerBuffer = [UInt8](repeating: 0, count: 16)

    // Peek at header until we find \r\n
    var chunkSize: Int = 0
    var headerLength: Int = 0

    while true {
        let peekLen = recv(socket, &headerBuffer, headerBuffer.count - 1, Int32(MSG_PEEK))
        if peekLen <= 0 {
            throw ConnectionError.receiveFailed
        }

        // Look for \r\n
        var endOfHeaderIndex: Int? = nil
        for i in 0..<(peekLen - 1) {
            if headerBuffer[i] == 13 && headerBuffer[i + 1] == 10 { // \r\n
                endOfHeaderIndex = i
                break
            }
        }

        guard let endIndex = endOfHeaderIndex else {
            continue
        }

        // Parse chunk size from hex header
        headerBuffer[endIndex] = 0
        let headerString = String(cString: headerBuffer)
        if let size = Int(headerString, radix: 16) {
            chunkSize = size
            headerLength = endIndex + 2 // Include \r\n
        } else {
            throw ConnectionError.headerParseFailed
        }

        // Consume the header
        _ = recv(socket, &headerBuffer, headerLength, 0)
        print("Chunk header received: \(chunkSize) (0x\(headerString))")
        break
    }

    // Read chunk data
    var data = Data()
    if chunkSize > 0 {
        var buffer = [UInt8](repeating: 0, count: CHUNK_SIZE)
        var bytesReceived = 0

        while bytesReceived < chunkSize {
            let remaining = chunkSize - bytesReceived
            let toRead = min(remaining, CHUNK_SIZE)
            let n = recv(socket, &buffer, toRead, 0)

            if n <= 0 {
                throw ConnectionError.receiveFailed
            }

            data.append(contentsOf: buffer.prefix(n))
            bytesReceived += n
        }
    }

    // Consume trailing \r\n
    var tmp = [UInt8](repeating: 0, count: 2)
    _ = recv(socket, &tmp, 2, 0)

    print("Chunk of \(chunkSize) received")
    return data
}
