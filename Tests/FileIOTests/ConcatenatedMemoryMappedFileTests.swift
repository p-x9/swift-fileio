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

    func testWriteEmptyData() throws {
        let size = Self.pageSize
        let initial = Data(repeating: 0xAB, count: size)
        try withTemporaryFile(size: size, contents: initial) { url in
            let file = try ConcatenatedMemoryMappedFile.open(
                url: url,
                isWritable: true
            )
            try file.writeData(Data(), at: 16)
            file.sync()
            XCTAssertEqual(try Data(contentsOf: url), initial)
        }
    }

    /// Reads the file back through the filesystem rather than through the
    /// mapping, so a mapping that never writes through cannot pass.
    func testWriteDataPersistsToDisk() throws {
        let size = Self.pageSize
        try withTemporaryFile(
            size: size,
            contents: Data(repeating: 0xAB, count: size)
        ) { url in
            let file = try ConcatenatedMemoryMappedFile.open(
                url: url,
                isWritable: true
            )
            let payload = Data([0x01, 0x02, 0x03, 0x04])
            try file.writeData(payload, at: 16)
            file.sync()

            let onDisk = try Data(contentsOf: url)
            XCTAssertEqual(onDisk.count, size)
            XCTAssertEqual(onDisk[16..<20], payload)
            XCTAssertEqual(onDisk[0..<16], Data(repeating: 0xAB, count: 16))
        }
    }

    func testWriteTypedPersistsToDisk() throws {
        let size = Self.pageSize
        try withTemporaryFile(
            size: size,
            contents: Data(repeating: 0, count: size)
        ) { url in
            let file = try ConcatenatedMemoryMappedFile.open(
                url: url,
                isWritable: true
            )
            try file.write(UInt32(0xDEADBEEF), at: 32)
            file.sync()

            let onDisk = try Data(contentsOf: url)
            let readBack = onDisk[32..<36].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self)
            }
            XCTAssertEqual(readBack, 0xDEADBEEF)
        }
    }

    /// A write straddling the seam between two mapped files must land in both
    /// of them, which is the whole point of the concatenated mapping.
    func testWriteAcrossSegmentBoundaryPersistsToDisk() throws {
        let size = Self.pageSize
        try withTemporaryFiles(
            files: [
                (size: size, contents: Data(repeating: 0xAA, count: size)),
                (size: size, contents: Data(repeating: 0xBB, count: size)),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: true
            )
            XCTAssertEqual(file.size, size * 2)

            // Two bytes before the seam, two bytes after it.
            let payload = Data([0x01, 0x02, 0x03, 0x04])
            try file.writeData(payload, at: size - 2)
            file.sync()

            let first = try Data(contentsOf: urls[0])
            let second = try Data(contentsOf: urls[1])

            XCTAssertEqual(first[(size - 2)..<size], payload[0..<2])
            XCTAssertEqual(second[0..<2], payload[2..<4])

            // Everything outside the written range is untouched.
            XCTAssertEqual(
                first[0..<(size - 2)],
                Data(repeating: 0xAA, count: size - 2)
            )
            XCTAssertEqual(
                second[2..<size],
                Data(repeating: 0xBB, count: size - 2)
            )
        }
    }
}
