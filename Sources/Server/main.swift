/*
 * Server using librsync streaming API
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
import Clibrsync
import RsyncSwift

#if os(Linux)
import Glibc
#else
import Darwin
#endif

// MARK: - Socket Extensions

extension sockaddr_in {
    /// Initialize a server sockaddr_in that binds to any address
    init(port: UInt16) {
        self.init()
        self.sin_family = sa_family_t(AF_INET)
        self.sin_addr.s_addr = INADDR_ANY.bigEndian
        self.sin_port = port.bigEndian
    }

    /// Execute a closure with a pointer to sockaddr (immutable)
    func withSockaddrPointer<Result>(_ body: (UnsafePointer<sockaddr>) -> Result) -> Result {
        var addr = self
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }

    /// Execute a closure with a mutable pointer to sockaddr
    mutating func withMutableSockaddrPointer<Result>(_ body: (UnsafeMutablePointer<sockaddr>) -> Result) -> Result {
        return withUnsafeMutablePointer(to: &self) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }
}

/// Accept an incoming connection
func acceptConnection() throws -> Int32 {
    // Create socket
    #if os(Linux)
    let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    #endif

    guard sock != -1 else {
        throw ConnectionError.socketCreationFailed
    }

    // Enable address reuse
    var opt: Int32 = 1
    _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

    // Setup server address
    let serverAddr = sockaddr_in(port: PORT)

    // Bind socket
    let bindResult = serverAddr.withSockaddrPointer { sockaddrPtr in
        bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    guard bindResult != -1 else {
        close(sock)
        throw ConnectionError.bindFailed
    }

    // Listen for incoming connections
    guard listen(sock, 1) != -1 else {
        close(sock)
        throw ConnectionError.listenFailed
    }

    // Accept incoming connection
    var clientAddr = sockaddr_in()
    var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    let conn = clientAddr.withMutableSockaddrPointer { sockaddrPtr in
        accept(sock, sockaddrPtr, &addrLen)
    }

    close(sock)

    guard conn != -1 else {
        throw ConnectionError.acceptFailed
    }

    return conn
}

/// Receive signature from client
func receiveSignature(socket: Int32) throws -> OpaquePointer {
    var signature: OpaquePointer? = nil
    let job = rs_loadsig_begin(&signature)
    guard job != nil else {
        fatalError("Failed to create loadsig job")
    }

    var bufs = rs_buffers_t()
    var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)

    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }

    var res: rs_result = RS_RUNNING

    repeat {
        if bufs.eof_in == 0 {
            if bufs.avail_in > BUFFER_SIZE {
                fputs("Insufficient buffer capacity", stderr)
                rs_job_free(job)
                throw ConnectionError.insufficientBuffer
            }

            if bufs.avail_in > 0 {
                // Move leftover data to front
                inBuffer.withUnsafeMutableBytes { dest in
                    _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                }
            }

            // Read chunk
            let data = try readChunk(socket: socket)
            let nBytes = data.count

            if nBytes > 0 {
                inBuffer.withUnsafeMutableBytes { dest in
                    data.withUnsafeBytes { bytes in
                        _ = memcpy(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), bytes.baseAddress!, nBytes)
                    }
                }
            }

            bufs.eof_in = (nBytes == 0) ? 1 : 0
            print("Received \(nBytes) bytes")

            bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_in += nBytes
        }

        res = rs_job_iter(job, &bufs)
        if res != RS_DONE && res != RS_BLOCKED {
            rs_job_free(job)
            print("ERROR: Not done and not blocked: \(res)")
            throw ConnectionError.receiveFailed
        }
    } while res != RS_DONE

    rs_job_free(job)

    guard let sig = signature else {
        fatalError("Signature is nil after loading")
    }

    return sig
}

/// Send delta to client
func sendDelta(socket: Int32, signature: OpaquePointer, filename: String) throws {
    // Open file
    guard let file = rs_file_open(filename, "rb", 0) else {
        fatalError("Failed to open file")
    }

    // Build hash table
    let res = rs_build_hash_table(signature)
    if res != RS_DONE {
        rs_file_close(file)
        throw ConnectionError.sendFailed
    }

    // Start generating delta
    guard let job = rs_delta_begin(signature) else {
        fatalError("Failed to create delta job")
    }

    var bufs = rs_buffers_t()
    var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
    var outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)

    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
    bufs.avail_out = BUFFER_SIZE

    var deltaRes: rs_result = RS_RUNNING

    repeat {
        if bufs.eof_in == 0 {
            if bufs.avail_in >= inBuffer.count {
                print("Insufficient buffer capacity. Avail: \(bufs.avail_in) in_buf \(inBuffer.count)")
                rs_file_close(file)
                rs_job_free(job)
                throw ConnectionError.insufficientBuffer
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
                    perror("Failed to read file")
                    rs_file_close(file)
                    rs_job_free(job)
                    throw ConnectionError.sendFailed
                }
                bufs.eof_in = feof(file) != 0 ? 1 : 0
            }

            bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_in += nBytes
        }

        deltaRes = rs_job_iter(job, &bufs)
        if deltaRes != RS_DONE && deltaRes != RS_BLOCKED {
            print("ERROR: Not done and not blocked: \(deltaRes)")
            rs_file_close(file)
            rs_job_free(job)
            throw ConnectionError.sendFailed
        }

        // Drain output buffer
        let present = outBuffer.withInt8Pointer { baseAddr in
            guard let nextOut = bufs.next_out else { return 0 }
            return UnsafePointer(nextOut) - baseAddr
        }
        if present > 0 {
            assert(present <= BUFFER_SIZE)
            let data = Data(bytes: outBuffer, count: present)
            try writeChunk(socket: socket, buffer: data)
            print("Sent \(present) bytes")

            bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_out = BUFFER_SIZE
        }
    } while deltaRes != RS_DONE

    // Send EOF chunk
    try writeChunk(socket: socket, buffer: Data())

    rs_file_close(file)
    rs_job_free(job)
}

// Main program
guard CommandLine.arguments.count >= 2 else {
    print("USAGE: \(CommandLine.arguments[0]) <FILENAME>")
    exit(EXIT_FAILURE)
}

let filename = CommandLine.arguments[1]

do {
    print("Waiting for connection...")
    let socket = try acceptConnection()

    print("Receiving signature...")
    let signature = try receiveSignature(socket: socket)

    print("Sending delta...")
    try sendDelta(socket: socket, signature: signature, filename: filename)
    rs_free_sumset(signature)

    close(socket)
    print("Success!")
    exit(EXIT_SUCCESS)
} catch {
    print("Error: \(error)")
    exit(EXIT_FAILURE)
}
