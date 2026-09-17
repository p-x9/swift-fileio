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
    /// Segments no longer need to be page-size multiples, but keeping some
    /// fixtures page-sized preserves the original coverage.
    private static var pageSize: Int { systemPageSize }

    /// A failing `open` must surface the platform error number instead of
    /// trapping. The concatenated variant opens in a loop, so this also
    /// covers the cleanup path for descriptors already opened.
    func testOpenMissingFileThrowsSystemError() throws {
        let size = Self.pageSize
        try withTemporaryFile(size: size) { existing in
            let missing = URL(
                fileURLWithPath: "/nonexistent-\(UUID().uuidString)/file"
            )
            XCTAssertThrowsError(
                try ConcatenatedMemoryMappedFile.open(
                    urls: [existing, missing],
                    isWritable: false
                )
            ) { error in
                XCTAssertEqual(error as? FileIOError, .system(code: ENOENT))
            }
        }
    }

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

    /// The previous implementation reserved one address range and overlaid
    /// each file with MAP_FIXED, which requires every segment to be a page
    /// multiple -- unaligned sizes failed with EINVAL. Mapping each file
    /// separately removes the restriction entirely.
    func testUnalignedSegmentSizes() throws {
        let a = Self.pageSize + 100
        let b = 37
        let c = Self.pageSize * 2 + 1
        try withTemporaryFiles(
            files: [
                (size: a, contents: Data(repeating: 0xAA, count: a)),
                (size: b, contents: Data(repeating: 0xBB, count: b)),
                (size: c, contents: Data(repeating: 0xCC, count: c)),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: false
            )
            XCTAssertEqual(file.size, a + b + c)
            XCTAssertEqual(try file.readData(offset: a - 1, length: 2), Data([0xAA, 0xBB]))
            XCTAssertEqual(try file.readData(offset: a + b - 1, length: 2), Data([0xBB, 0xCC]))
            XCTAssertEqual(
                try file.readAllData(),
                Data(repeating: 0xAA, count: a)
                    + Data(repeating: 0xBB, count: b)
                    + Data(repeating: 0xCC, count: c)
            )
        }
    }

    /// A read covering three segments end to end.
    func testReadSpanningMultipleSegments() throws {
        let size = 64
        try withTemporaryFiles(
            files: (0..<3).map { i in
                (size: size, contents: Data(repeating: UInt8(0x10 + i), count: size))
            }
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: false
            )
            let read = try file.readData(offset: size - 2, length: size + 4)
            XCTAssertEqual(
                read,
                Data(repeating: 0x10, count: 2)
                    + Data(repeating: 0x11, count: size)
                    + Data(repeating: 0x12, count: 2)
            )
        }
    }

    /// `unsafeRegion(at:)` must report where the contiguous run ends, since
    /// reading past it leaves the segment's mapping.
    func testUnsafeRegionReportsContiguousRun() throws {
        let a = 100
        let b = 50
        try withTemporaryFiles(
            files: [
                (size: a, contents: Data(repeating: 0xAA, count: a)),
                (size: b, contents: Data(repeating: 0xBB, count: b)),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: false
            )

            let r0 = try file.unsafeRegion(at: 0)
            XCTAssertEqual(r0.count, a, "run should stop at the end of segment 0")
            XCTAssertEqual(r0.pointer.load(as: UInt8.self), 0xAA)
            XCTAssertEqual(r0.buffer.count, a)

            let r1 = try file.unsafeRegion(at: a - 1)
            XCTAssertEqual(r1.count, 1, "one byte left in segment 0")
            XCTAssertEqual(r1.pointer.load(as: UInt8.self), 0xAA)

            let r2 = try file.unsafeRegion(at: a)
            XCTAssertEqual(r2.count, b, "crossing the seam starts segment 1")
            XCTAssertEqual(r2.pointer.load(as: UInt8.self), 0xBB)

            XCTAssertThrowsError(try file.unsafeRegion(at: a + b)) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    /// A typed value straddling a seam cannot be loaded through one pointer,
    /// so it has to go through the copying path.
    func testTypedReadWriteAcrossSegmentBoundary() throws {
        let size = 64
        try withTemporaryFiles(
            files: [
                (size: size, contents: Data(repeating: 0, count: size)),
                (size: size, contents: Data(repeating: 0, count: size)),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: true
            )
            // Two bytes before the seam: the UInt32 spans both files.
            try file.write(UInt32(0xDEADBEEF), at: size - 2)
            file.sync()

            XCTAssertEqual(try file.read(offset: size - 2, as: UInt32.self), 0xDEADBEEF)

            let first = try Data(contentsOf: urls[0])
            let second = try Data(contentsOf: urls[1])
            let rejoined = first[(size - 2)..<size] + second[0..<2]
            XCTAssertEqual(
                rejoined.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) },
                0xDEADBEEF
            )
        }
    }

    func testFileSliceAcrossSegmentBoundary() throws {
        let size = 32
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
            let slice = try file.fileSlice(offset: size - 4, length: 8)
            XCTAssertEqual(slice.size, 8)
            XCTAssertEqual(
                try slice.readAllData(),
                Data(repeating: 0xAA, count: 4) + Data(repeating: 0xBB, count: 4)
            )

            // The slice's contiguous run is clamped by both the segment and
            // the slice's own end.
            XCTAssertEqual(try slice.unsafeRegion(at: 0).count, 4)

            try slice.writeData(Data([1, 2, 3, 4, 5, 6]), at: 1)
            slice.sync()
            XCTAssertEqual(
                try file.readData(offset: size - 3, length: 6),
                Data([1, 2, 3, 4, 5, 6])
            )
        }
    }

    /// Empty segments used to be rejected with a stale errno; they now just
    /// contribute nothing.
    func testEmptySegmentIsSkipped() throws {
        try withTemporaryFiles(
            files: [
                (size: 4, contents: Data([1, 2, 3, 4])),
                (size: 0, contents: Data()),
                (size: 4, contents: Data([5, 6, 7, 8])),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: false
            )
            XCTAssertEqual(file.size, 8)
            XCTAssertEqual(try file.readAllData(), Data([1, 2, 3, 4, 5, 6, 7, 8]))
        }
    }
}

extension ConcatenatedMemoryMappedFileTests {
    /// The typed paths no longer check the whole file before looking up the
    /// segment, so these pin that the lookup rejects the same offsets the
    /// removed check did.
    func testTypedAccessRejectsOffsetsOutsideEverySegment() throws {
        try withTemporaryFiles(
            files: [
                (size: 4, contents: Data([1, 2, 3, 4])),
                (size: 4, contents: Data([5, 6, 7, 8])),
            ]
        ) { urls in
            let file = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: true
            )
            XCTAssertEqual(file.size, 8)

            for offset in [-1, 8, 9, Int.min, Int.max] {
                XCTAssertThrowsError(
                    try file.read(offset: offset, as: UInt8.self)
                ) { error in
                    XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
                }
                XCTAssertThrowsError(
                    try file.write(UInt8(0xEE), at: offset)
                ) { error in
                    XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
                }
            }

            // In range, but the value runs off the end of the last segment,
            // so it takes the straddling path and is rejected there.
            XCTAssertThrowsError(
                try file.read(offset: 7, as: UInt32.self)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
            XCTAssertThrowsError(
                try file.write(UInt32(0), at: 7)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }

            // A value straddling the seam still works.
            XCTAssertEqual(try file.read(offset: 3, as: UInt16.self), 0x0504)
        }
    }
}
