//
//  ConcatenatedMemoryMappedFileTests.swift
//  swift-fileio
//

import XCTest
@testable import FileIO

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Android)
import Android
#endif

final class ConcatenatedMemoryMappedFileTests: XCTestCase {}

extension ConcatenatedMemoryMappedFileTests {
    /// `ConcatenatedMemoryMappedFile` requires each segment to be a multiple
    /// of the page size, so use that for fixtures.
    private static var pageSize: Int { Int(getpagesize()) }

    func testReadTypedNegativeOffset() throws {
        let size = Self.pageSize
        try withTemporaryFile(size: size) { url in
            let file = try ConcatenatedMemoryMappedFile.open(
                url: url,
                isWritable: false
            )
            XCTAssertThrowsError(
                try file.read(offset: -1, as: UInt32.self)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testWriteTypedNegativeOffset() throws {
        let size = Self.pageSize
        try withTemporaryFile(size: size) { url in
            let file = try ConcatenatedMemoryMappedFile.open(
                url: url,
                isWritable: true
            )
            XCTAssertThrowsError(
                try file.write(UInt32(0), at: -1)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }
}
