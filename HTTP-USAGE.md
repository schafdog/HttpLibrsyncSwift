# HTTP-based librsync Implementation

This document describes how to use the HTTP-based implementation of librsync using Hummingbird and AsyncHTTPClient.

## Overview

The HTTP implementation provides an alternative to the direct TCP socket approach, offering:

- **Standard HTTP protocol** - Works with existing HTTP infrastructure (load balancers, reverse proxies, etc.)
- **Streaming body support** - Efficient transfer of large signatures and deltas
- **RESTful API** - Push-based sync where clients upload changes to server
- **Better network compatibility** - HTTP typically works through firewalls and corporate proxies

## Architecture

This implementation uses a **push model** where clients upload their changes to the server.

### Server (HTTPServer)
Built with **Hummingbird**, the server provides two endpoints:

- `GET /signature?file=<filename>` - Streams signature of the server's file
- `POST /delta?file=<filename>` - Receives delta and applies it to update the server's file

The server:
1. On GET /signature: Generates and streams a signature from its file
2. On POST /delta: Receives delta stream, applies it to its file, creates updated file

### Client (HTTPClient)
Built with **AsyncHTTPClient**, the client intelligently syncs files:
1. Requests signature from server (GET /signature)
2. **If 404 (file not found)**: Uploads entire file via POST /upload
3. **If 200 (file exists)**:
   - Loads signature from response stream
   - Generates delta from local file using the server's signature
   - Streams delta to server (POST /delta)

## Building

```bash
cd RsyncSwift
swift build
```

This will build:
- `Server` (TCP version)
- `Client` (TCP version)
- `HTTPServer` (HTTP version)
- `HTTPClient` (HTTP version)

## Usage

### 1. Start the HTTP Server

```bash
.build/debug/HTTPServer
```

The server will start on `http://127.0.0.1:8081` and can serve any file requested by clients.

### 2. Run the HTTP Client

To push your local changes to the server:

```bash
.build/debug/HTTPClient path/to/file.txt http://127.0.0.1:8081
```

This will:
1. Request signature from server's file
2. **If file doesn't exist on server**: Upload full file
3. **If file exists**: Generate and upload delta
   - Load signature from response
   - Generate delta from local file using server's signature
   - Upload delta to server
   - Server applies delta and creates `file.txt.new`

## Examples

### Example 1: Syncing when server has an old version
**Server side:**
```bash
# Server has an old version of README.md
.build/debug/HTTPServer
```

**Client side:**
```bash
# Client has updated README.md and wants to push changes
.build/debug/HTTPClient README.md http://192.168.1.100:8081
# Output: "Loading signature from server..."
# Output: "Sending delta to server..."
# Server creates README.md.new with the client's version
```

### Example 2: Uploading a new file
**Server side:**
```bash
# Server doesn't have config.json yet
.build/debug/HTTPServer
```

**Client side:**
```bash
# Client wants to upload a new file
.build/debug/HTTPClient config.json http://192.168.1.100:8081
# Output: "Server doesn't have the file. Uploading full file..."
# Server creates config.json with the full file content
```

## API Details

### Get Signature Endpoint

```
GET /signature?file=<filename>
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: application/octet-stream
Transfer-Encoding: chunked

<signature data stream>
```

### Upload Full File Endpoint

```
POST /upload?file=<filename>
Content-Type: application/octet-stream
Transfer-Encoding: chunked

<file data stream>
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

File uploaded successfully. Received <N> bytes
```

### Upload Delta Endpoint

```
POST /delta?file=<filename>
Content-Type: application/octet-stream
Transfer-Encoding: chunked

<delta data stream>
```

**Response:**
```
HTTP/1.1 200 OK
Content-Type: text/plain

Delta applied successfully. Created <filename>.new
```

## Comparison: TCP vs HTTP

### TCP Implementation (Server/Client)
- **Pull model**: Client pulls updates from server
- Direct socket communication
- Custom chunked transfer encoding
- Lower overhead
- Requires custom port management
- Better for internal networks

### HTTP Implementation (HTTPServer/HTTPClient)
- **Push model**: Client pushes updates to server
- Standard HTTP protocol
- Native HTTP chunked encoding
- Works with HTTP infrastructure
- Standard port (8081, can be changed)
- Better for internet-facing services
- Useful for uploading changes from clients to a central server

## Performance Considerations

- **Streaming**: All transfers (signature, delta, full file) use streaming, so memory usage remains constant regardless of file size
- **Automatic optimization**: Client automatically chooses between full upload and delta based on server's file availability
- **Buffer sizes**: Configured in `RsyncSwift/Connection.swift` (`BUFFER_SIZE = 16 * 4096`)
- **Network**: HTTP adds minimal overhead compared to raw TCP
- **Efficiency**: For small changes, delta sync can reduce bandwidth by 90%+ compared to full file upload

## Error Handling

The implementation handles:
- File not found errors
- librsync processing errors
- Network errors
- Buffer overflow protection

Errors are logged to stdout and returned as HTTP error responses when appropriate.

## Dependencies

- **Hummingbird 2.0+**: Modern Swift HTTP server framework
- **AsyncHTTPClient 1.9+**: Async/await HTTP client with streaming support
- **librsync**: The underlying rsync library (via Clibrsync module)

## Future Enhancements

Possible improvements:
- Authentication/authorization
- Multiple file support
- Compression
- Progress reporting
- Persistent signature caching
- WebSocket support for real-time sync
