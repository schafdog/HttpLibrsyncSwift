# LibrsyncWrapper - Modern Swift API for librsync

A type-safe, streaming-first Swift wrapper for librsync with full async/await support and Swift 6.2 compatibility.

## Features

- ✅ **Streaming API** - Constant memory usage for files of any size
- ✅ **AsyncSequence** - Native Swift concurrency support
- ✅ **Type-safe** - Comprehensive error handling
- ✅ **Thread-safe** - Full Sendable conformance
- ✅ **HTTP-ready** - Direct integration with AsyncHTTPClient/Hummingbird
- ✅ **In-memory convenience methods** - For small files

## Quick Start

### Streaming Signature Generation (for HTTP responses)

```swift
import RsyncSwift

let rsync = Librsync()
let fileURL = URL(fileURLWithPath: "myfile.txt")

// Stream signature chunks directly to HTTP response
let signatureStream = rsync.signatureStream(from: fileURL)

// Use with Hummingbird
return Response(
    status: .ok,
    headers: [.contentType: "application/octet-stream"],
    body: .init(asyncSequence: signatureStream.map { ByteBuffer(data: $0) })
)
```

### Loading Signature from HTTP Request

```swift
// Load signature from streaming HTTP request body
let signatureHandle = try await rsync.loadSignature(from: request.body.map { Data($0.readableBytesView) })
```

### Streaming Delta Generation (for HTTP responses)

```swift
// Generate delta stream against loaded signature
let deltaStream = rsync.deltaStream(from: newFileURL, against: signatureHandle)

// Stream directly to HTTP response
return Response(
    status: .ok,
    headers: [.contentType: "application/octet-stream"],
    body: .init(asyncSequence: deltaStream.map { ByteBuffer(data: $0) })
)
```

### In-Memory Operations (for small files)

```swift
// Generate complete signature in memory
let signatureData = try await rsync.generateSignature(from: oldFileURL)

// Load signature
let signatureHandle = try await rsync.loadSignature(from: signatureData)

// Generate complete delta in memory
let deltaData = try await rsync.generateDelta(from: newFileURL, against: signatureHandle)

// Apply patch
try await rsync.applyPatch(delta: deltaData, toBasis: oldFileURL, output: patchedFileURL)

// Or atomically replace original
try await rsync.patch(oldFileURL, with: deltaData)
```

### Complete HTTP Server Example

```swift
import Hummingbird
import RsyncSwift

// GET /signature?file=<filename>
func generateSignature(_ request: Request, context: some RequestContext) async throws -> Response {
    guard let filename = request.uri.queryParameters.get("file") else {
        throw HTTPError(.badRequest)
    }

    let fileURL = URL(fileURLWithPath: filename)
    let rsync = Librsync()

    // Stream signature with constant memory usage
    let stream = rsync.signatureStream(from: fileURL)

    return Response(
        status: .ok,
        headers: [
            .contentType: "application/octet-stream",
            .transferEncoding: "chunked"
        ],
        body: .init(asyncSequence: stream.map { ByteBuffer(data: $0) })
    )
}

// POST /delta?file=<filename>
func generateDelta(_ request: Request, context: some RequestContext) async throws -> Response {
    guard let filename = request.uri.queryParameters.get("file") else {
        throw HTTPError(.badRequest)
    }

    let fileURL = URL(fileURLWithPath: filename)
    let rsync = Librsync()

    // Load signature from streaming request body
    let signatureStream = request.body.map { Data($0.readableBytesView) }
    let signatureHandle = try await rsync.loadSignature(from: signatureStream)

    // Stream delta with constant memory usage
    let deltaStream = rsync.deltaStream(from: fileURL, against: signatureHandle)

    return Response(
        status: .ok,
        headers: [
            .contentType: "application/octet-stream",
            .transferEncoding: "chunked"
        ],
        body: .init(asyncSequence: deltaStream.map { ByteBuffer(data: $0) })
    )
}
```

## Configuration

Customize buffer sizes and hash parameters:

```swift
let config = LibrsyncConfig(
    bufferSize: 128 * 1024,        // 128KB buffer (default: 64KB)
    blockLength: 2048,              // Block size (default: auto)
    strongLength: 32,               // Hash length (default: auto)
    signatureMagic: RS_BLAKE2_SIG_MAGIC  // Signature format
)

let rsync = Librsync(config: config)
```

## Architecture

### Streaming-First Design

All operations return `AsyncSequence` for memory-efficient processing:

- `SignatureStream` - Streams signature chunks
- `DeltaStream` - Streams delta chunks
- `loadSignature(from: AsyncSequence)` - Loads signature from stream

### Thread Safety

- `SignatureHandle` uses internal locking for thread-safe access
- All types conform to `Sendable` for Swift 6.2
- No global state

### Error Handling

Comprehensive `LibrsyncError` enum:
- File errors (not found, read/write failures)
- librsync operation errors with result codes
- Buffer and state errors

## Memory Usage

- **Streaming operations**: O(buffer size) - constant memory
- **In-memory operations**: O(file size) - loads entire data

For large files (>100MB), always use streaming API.

## Integration with HTTP Frameworks

### AsyncHTTPClient

```swift
import AsyncHTTPClient

let signatureStream = rsync.signatureStream(from: fileURL)

var request = HTTPClientRequest(url: serverURL)
request.method = .POST
request.body = .stream(signatureStream.map { ByteBuffer(data: $0) }, length: .unknown)

let response = try await httpClient.execute(request, timeout: .hours(1))
```

### Hummingbird

```swift
import Hummingbird

let stream = rsync.deltaStream(from: fileURL, against: signatureHandle)

return Response(
    status: .ok,
    body: .init(asyncSequence: stream.map { ByteBuffer(data: $0) })
)
```

## Best Practices

1. **Use streaming for large files** - Keeps memory constant
2. **Reuse `Librsync` instances** - Configuration is immutable
3. **Handle errors properly** - Check for `LibrsyncError` cases
4. **Set appropriate timeouts** - Large files may take time
5. **Don't hold SignatureHandle longer than needed** - Auto-cleanup on deinit

## License

LGPL 2.1 - Same as librsync
