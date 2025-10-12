# LibrsyncSwift Tests

## Cross-Platform Testing Frameworks

### Swift Testing (Recommended - Swift 6.1+)

**LibrsyncSwiftTests.swift** - Modern Swift Testing framework that works cross-platform.

### XCTest (Legacy - Requires Xcode on macOS)

**LibrsyncWrapperTests.swift.xctest** - Traditional XCTest suite.

## Current Status

- **LibrsyncSwiftTests.swift**: ✅ Swift Testing suite (15 tests) - **Works with CommandLineTools!**
- **LibrsyncWrapperTests.swift.xctest**: XCTest suite (20 tests) - Requires Xcode on macOS
- **DummyTests.swift**: Old placeholder (no longer used)

## Running Tests

### Swift Testing (Current - Works Now!)

Swift Testing works with CommandLineTools on macOS since Swift 6.1+:

```bash
swift test
```

This runs the **LibrsyncSwiftTests.swift** suite with 15 modern tests.

### XCTest (Optional - Requires Xcode)

To run the additional XCTest suite, you need Xcode:

1. Install Xcode from the App Store
2. Switch to Xcode toolchain:
   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   ```
3. Enable the XCTest file:
   ```bash
   cd Tests/LibrsyncSwiftTests
   mv LibrsyncWrapperTests.swift.xctest LibrsyncWrapperTests.swift
   ```
4. Update Package.swift to remove `.xctest` from exclude list
5. Run all tests:
   ```bash
   swift test
   ```

### Linux Testing

Both frameworks work on Linux:

```bash
swift test  # Runs Swift Testing tests
```

Or via Docker:
```bash
docker run -v "$PWD:/code" -w /code swift:latest swift test
```

## Why Swift Testing?

Since Swift 6.1+, **Swift Testing is now the recommended framework**:

- ✅ Works on **macOS CommandLineTools** (no Xcode needed!)
- ✅ Works on **Linux**
- ✅ Modern syntax with `#expect` macros
- ✅ Better async/await support
- ✅ Parallel test execution by default
- ✅ More expressive test output
- ✅ Cross-platform from day one

**XCTest** is still valuable but requires Xcode on macOS.

## Test Coverage

Both test suites cover:

### Swift Testing Tests (LibrsyncSwiftTests.swift)
- ✅ Signature generation (small and large files)
- ✅ Signature streaming
- ✅ Delta generation (identical and modified files)
- ✅ Complete round-trip (text and binary data)
- ✅ Custom configuration
- ✅ Error handling and descriptions
- ✅ Thread safety (concurrent operations)
- ✅ Error throwing validation

### XCTest Tests (LibrsyncWrapperTests.swift.xctest)
All of the above plus:
- Extended signature loading tests (from data and streams)
- Delta generation for completely different files
- Delta streaming tests
- Patch application (with atomic rename)
- Invalid signature/basis file handling

Both test suites use comprehensive Given/When/Then structure with proper cleanup.
