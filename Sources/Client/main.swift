/*
 * client using librsync
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
import LibrsyncSwift

#if os(Linux)
import Glibc
#else
import Darwin
#endif

let IP_ADDRESS = "127.0.0.1"

// MARK: - Standard Error Stream

struct StandardErrorStream: TextOutputStream {
    mutating func write(_ string: String) {
        FileHandle.standardError.write(Data(string.utf8))
    }
}

nonisolated(unsafe) var standardErrorStream = StandardErrorStream()

// MARK: - Socket Extensions

extension sockaddr_in {
    /// Initialize a sockaddr_in with an IP address and port
    init?(ipAddress: String, port: UInt16) {
        self.init()
        self.sin_family = sa_family_t(AF_INET)
        self.sin_port = port.bigEndian

        #if os(Linux)
        guard inet_pton(AF_INET, ipAddress, &self.sin_addr) == 1 else {
            return nil
        }
        #else
        var s_addr: in_addr_t = 0
        guard inet_pton(AF_INET, ipAddress, &s_addr) == 1 else {
            return nil
        }
        self.sin_addr.s_addr = s_addr
        #endif
    }

    /// Execute a closure with a pointer to sockaddr
    func withSockaddrPointer<Result>(_ body: (UnsafePointer<sockaddr>) -> Result) -> Result {
        var addr = self
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1, body)
        }
    }
}

/// Connect to server
func connectToServer(ipAddress: String) throws -> Int32 {
    // Create socket
    #if os(Linux)
    let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    #endif

    guard sock != -1 else {
        throw ConnectionError.socketCreationFailed
    }

    // Setup address
    guard let addr = sockaddr_in(ipAddress: ipAddress, port: PORT) else {
        close(sock)
        throw ConnectionError.invalidAddress
    }

    // Connect to server
    let result = addr.withSockaddrPointer { sockaddrPtr in
        connect(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
    }

    guard result != -1 else {
        close(sock)
        throw ConnectionError.connectFailed
    }

    return sock
}

/// Send signature to server
func sendSignature(socket: Int32, filename: String) throws {
    // Open basis file
    guard let file = rs_file_open(filename, "rb", 0) else {
        fatalError("Failed to open file")
    }

    // Get file size
    let fsize = rs_file_size(file)

    // Get recommended arguments
    var sigMagic: rs_magic_number = rs_magic_number(rawValue: 0)
    var blockLen: Int = 0
    var strongLen: Int = 0

    let res = rs_sig_args(fsize, &sigMagic, &blockLen, &strongLen)
    if res != RS_DONE {
        rs_file_close(file)
        throw ConnectionError.sendFailed
    }

    // Start generating signature
    guard let job = rs_sig_begin(blockLen, strongLen, sigMagic) else {
        fatalError("Failed to create signature job")
    }

    var bufs = rs_buffers_t()
    var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
    var outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)

    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
    bufs.avail_out = BUFFER_SIZE

    var sigRes: rs_result = RS_RUNNING

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

            // Fill input buffer
            var nBytes: Int = 0
            let bufferSize = inBuffer.count
            inBuffer.withUnsafeMutableBytes { dest in
                nBytes = fread(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), 1, bufferSize - Int(bufs.avail_in), file)
            }
            print("Read \(nBytes) bytes from file")

            if nBytes == 0 {
                if ferror(file) != 0 {
                    perror("Failed to read file")
                    rs_file_close(file)
                    rs_job_free(job)
                    throw ConnectionError.sendFailed
                }
                bufs.eof_in = feof(file) != 0 ? 1 : 0
                assert(bufs.eof_in != 0)
            }

            bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_in += nBytes
        }

        print("job running")
        sigRes = rs_job_iter(job, &bufs)
        if sigRes != RS_DONE && sigRes != RS_BLOCKED {
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
            print("Sending \(present) bytes")
            let data = Data(bytes: outBuffer, count: present)
            try writeChunk(socket: socket, buffer: data)

            bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_out = BUFFER_SIZE
        }
    } while sigRes != RS_DONE

    // Send EOF chunk
    try writeChunk(socket: socket, buffer: Data())

    rs_file_close(file)
    rs_job_free(job)
}

/// Receive delta and patch file
func receiveDeltaAndPatchFile(socket: Int32, filename: String) throws {
    let newFilename = filename + ".new"

    // Open new file
    guard let newFile = rs_file_open(newFilename, "wb", 1) else {
        fatalError("Failed to open new file")
    }

    // Open basis file
    guard let oldFile = rs_file_open(filename, "rb", 0) else {
        fatalError("Failed to open old file")
    }

    guard let job = rs_patch_begin(rs_file_copy_cb, oldFile) else {
        fatalError("Failed to create patch job")
    }

    var bufs = rs_buffers_t()
    var inBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 2)
    var outBuffer = [UInt8](repeating: 0, count: BUFFER_SIZE * 4)

    bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
    bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
    bufs.avail_out = outBuffer.count

    var patchRes: rs_result = RS_RUNNING

    repeat {
        if bufs.eof_in == 0 {
            if bufs.avail_in > BUFFER_SIZE {
                print("Insufficient buffer capacity", to: &standardErrorStream)
                fclose(newFile)
                fclose(oldFile)
                rs_job_free(job)
                throw ConnectionError.insufficientBuffer
            }

            if bufs.avail_in > 0 {
                inBuffer.withUnsafeMutableBytes { dest in
                    _ = memmove(dest.baseAddress!, bufs.next_in, bufs.avail_in)
                }
            }

            // Read chunk
            let data = try readChunk(socket: socket)
            let nBytes = data.count
            print("Received \(nBytes) bytes")

            if nBytes > 0 {
                inBuffer.withUnsafeMutableBytes { dest in
                    data.withUnsafeBytes { bytes in
                        _ = memcpy(dest.baseAddress!.advanced(by: Int(bufs.avail_in)), bytes.baseAddress!, nBytes)
                    }
                }
            }

            bufs.eof_in = (nBytes == 0) ? 1 : 0

            bufs.next_in = inBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_in += nBytes
        }

        patchRes = rs_job_iter(job, &bufs)
        if patchRes != RS_DONE && patchRes != RS_BLOCKED {
            rs_file_close(newFile)
            rs_file_close(oldFile)
            rs_job_free(job)
            throw ConnectionError.receiveFailed
        }

        // Drain output buffer
        let present = outBuffer.withInt8Pointer { baseAddr in
            guard let nextOut = bufs.next_out else { return 0 }
            return UnsafePointer(nextOut) - baseAddr
        }
        if present > 0 {
            let written = fwrite(outBuffer, 1, present, newFile)
            if written == 0 {
                perror("Failed to write to file")
                rs_file_close(newFile)
                rs_file_close(oldFile)
                rs_job_free(job)
                throw ConnectionError.receiveFailed
            }

            bufs.next_out = outBuffer.withMutableInt8Pointer { $0 }
            bufs.avail_out = outBuffer.count
        }
    } while patchRes != RS_DONE

    rs_file_close(newFile)
    rs_file_close(oldFile)
    rs_job_free(job)
}

// Main program
guard CommandLine.arguments.count >= 2 else {
    print("USAGE: \(CommandLine.arguments[0]) <FILENAME>")
    exit(EXIT_FAILURE)
}

let filename = CommandLine.arguments[1]

do {
    print("Connecting to server...")
    let socket = try connectToServer(ipAddress: IP_ADDRESS)

    print("Sending signature...")
    try sendSignature(socket: socket, filename: filename)

    print("Receiving delta and patching file...")
    try receiveDeltaAndPatchFile(socket: socket, filename: filename)

    close(socket)
    print("Success!")
    exit(EXIT_SUCCESS)
} catch {
    print("Error: \(error)")
    exit(EXIT_FAILURE)
}
