# RsyncSwift

A Swift implementation of the librsync streaming example, demonstrating delta synchronization over a network using chunked transfer encoding.

## Overview

This project is a Swift port of the C-based `server.c` and `client.c` examples that demonstrate librsync's streaming delta synchronization capabilities. The implementation uses:

- **librsync**: For signature generation, delta computation, and file patching
- **Chunked Transfer Encoding**: HTTP-style chunked encoding for efficient network streaming
- **Swift System APIs**: Native Swift networking using BSD sockets

## Project Structure

```
RsyncSwift/
├── Package.swift                 # Swift Package Manager manifest
├── Sources/
│   ├── Clibrsync/               # C library module map for librsync
│   │   └── module.modulemap
│   ├── RsyncSwift/              # Shared connection utilities
│   │   └── Connection.swift      # Chunked transfer encoding implementation
│   ├── Server/                   # Server executable
│   │   └── main.swift
│   └── Client/                   # Client executable
│       └── main.swift
```

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

```bash
cd RsyncSwift
swift build
```

The executables will be located in `.build/debug/`:
- `.build/debug/Server`
- `.build/debug/Client`

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

### Network Port

Default port: **5612** (defined in `Connection.swift`)

### Buffer Sizes

- `BUFFER_SIZE`: 65536 bytes (16 * 4096)
- `CHUNK_SIZE`: Same as BUFFER_SIZE

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
