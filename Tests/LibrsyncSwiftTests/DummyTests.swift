/*
 * Placeholder test file for LibrsyncSwift
 *
 * Note: Full tests require XCTest which is only available with full Xcode installation.
 * The actual test file (LibrsyncWrapperTests.swift.disabled) needs to be renamed
 * and run with Xcode or after installing full Xcode.
 *
 * To enable full tests:
 * 1. Install Xcode from App Store
 * 2. Run: sudo xcode-select --switch /Applications/Xcode.app
 * 3. Rename LibrsyncWrapperTests.swift.disabled to LibrsyncWrapperTests.swift
 * 4. Run: swift test
 */

import Foundation
@testable import LibrsyncSwift

// Minimal compile-time verification that module imports work
func testModuleImports() {
    _ = Librsync()
}
