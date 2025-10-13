# HttpLibrsyncSwift

HTTP and TCP implementations for librsync streaming delta synchronization using the LibrsyncSwift library.

## Overview

This project demonstrates delta synchronization over networks using the [LibrsyncSwift](../LibrsyncSwift) library. It provides both HTTP-based and TCP-based implementations:

- **HTTP Implementation**: Modern async/await using Hummingbird server and AsyncHTTPClient
- **TCP Implementation**: Direct socket implementation with chunked transfer encoding
- **LibrsyncSwift**: Standalone Swift wrapper for librsync (in separate package)

## Project Structure

```
HttpLibrsyncSwift/
├── Package.swift                 # Swift Package Manager manifest
├── Sources/
│   ├── HTTPServer/              # HTTP server using Hummingbird
│   ├── HTTPClient/              # HTTP client using AsyncHTTPClient
│   ├── Server/                  # TCP server executable
│   └── Client/                  # TCP client executable
└── Tests/
```

## Dependencies

This project depends on:
- **LibrsyncSwift**: Local path dependency `https://github.com/schafdog/LibrsyncSwift` (standalone library)
- **Hummingbird**: HTTP server framework
- **AsyncHTTPClient**: HTTP client library

## Features

- **Signature Generation**: Client generates a signature of its local file
- **Delta Transmission**: Server computes and sends only the differences
- **File Patching**: Client applies the delta to reconstruct the updated file
- **Streaming Protocol**: Efficient chunked transfer encoding over TCP

## Prerequisites

### Linux
```bash
sudo apt-get install librsync-dev
```

### macOS
```bash
brew install librsync
```

## Building

First, ensure the LibrsyncSwift library is available at `https://github.com/schafdog/LibrsyncSwift`, then:

```bash
cd HttpLibrsyncSwift
swift build
```

The executables will be located in `.build/debug/`:
- `.build/debug/Server` (TCP server)
- `.build/debug/Client` (TCP client)
- `.build/debug/HTTPServer` (HTTP server)
- `.build/debug/HTTPClient` (HTTP client)

## Usage

### Running the Server

The server accepts connections and sends deltas based on received signatures:

```bash
.build/debug/Server <filename>
```

Example:
```bash
.build/debug/Server document.txt
```

The server will:
1. Listen on port 5612
2. Wait for a client connection
3. Receive a signature from the client
4. Compute and send the delta

### Running the Client

The client connects to the server and updates its local file:

```bash
.build/debug/Client <filename>
```

Example:
```bash
.build/debug/Client document.txt
```

The client will:
1. Connect to localhost:5612
2. Generate and send a signature of its local file
3. Receive the delta from the server
4. Apply the delta to create `<filename>.new`

## Protocol Details

### Chunked Transfer Encoding

The implementation uses HTTP-style chunked encoding:

```
<chunk-size-hex>\r\n
<chunk-data>
\r\n
```

A zero-length chunk signals EOF:
```
0\r\n
\r\n
```

### Network Ports

- TCP Server: **5612** (default)
- HTTP Server: **8080** (default)

### Buffer Sizes

- `BUFFER_SIZE`: 65536 bytes (16 * 4096)
- `CHUNK_SIZE`: Same as BUFFER_SIZE

## LibrsyncSwift Library

The librsync Swift wrapper has been extracted into a standalone package located at `../LibrsyncSwift`.

Key features:
- Streaming API with AsyncSequence
- Full Swift 6 concurrency support
- Type-safe error handling
- Thread-safe operations
- Constant memory usage for large files

See [LibrsyncSwift/README.md](../LibrsyncSwift/README.md) for detailed documentation.

## Implementation Notes

### Key Swift Conversions

1. **Socket Types**: Platform-specific handling for Linux vs macOS
   ```swift
   #if os(Linux)
   let sock = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
   #else
   let sock = socket(AF_INET, SOCK_STREAM, 0)
   #endif
   ```

2. **Pointer Management**: Safe handling of C pointers in Swift
   ```swift
   inBuffer.withUnsafeMutableBytes { dest in
       memmove(dest.baseAddress!, source, count)
   }
   ```

3. **Memory Safety**: Avoided overlapping access issues by capturing buffer sizes before closure execution

4. **Error Handling**: Swift `throws` and `do-catch` instead of C return codes

## Limitations

- Single connection at a time
- Localhost only (hardcoded IP_ADDRESS = "127.0.0.1" in client)
- No SSL/TLS support
- Basic error handling

## Future Enhancements

- [ ] Support for multiple simultaneous connections
- [ ] Configurable server address
- [ ] TLS encryption
- [ ] Progress reporting
- [ ] Compression
- [ ] Async/await API

## License

This is a derivative work based on the librsync examples:
- Original Copyright (C) 2024 by Lars Erik Wik <lars.erik.wik@northern.tech>
- Licensed under LGPL 2.1 or later

Swift conversion by Claude Code.

## References

- [librsync Documentation](https://librsync.github.io/)
- [Chunked Transfer Encoding](https://en.wikipedia.org/wiki/Chunked_transfer_encoding)
- [Swift Package Manager](https://swift.org/package-manager/)
