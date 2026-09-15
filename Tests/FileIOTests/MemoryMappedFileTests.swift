//
//  MemoryMappedFileTests.swift
//  swift-fileio
//
//  Created by p-x9 on 2026/01/06
//  
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

final class MemoryMappedFileTests: XCTestCase {}

extension MemoryMappedFileTests {
    func testOpenAndSize() throws {
        try withTemporaryFile(size: 1024) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertEqual(file.size, 1024)
        }
    }

    func testOpenEmptyFile() throws {
        try withTemporaryFile(size: 0) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertEqual(file.size, 0)
        }
    }

    /// A failing `open` must surface the platform error number instead of
    /// trapping, which is what `POSIXError(.init(rawValue: errno)!)` did for
    /// any code Foundation does not model.
    func testOpenMissingFileThrowsSystemError() throws {
        let url = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/file")
        XCTAssertThrowsError(
            try MemoryMappedFile.open(url: url, isWritable: false)
        ) { error in
            XCTAssertEqual(error as? FileIOError, .system(code: ENOENT))
        }
    }
}

extension MemoryMappedFileTests {
    func testReadData() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])

        try withTemporaryFile(size: data.count, contents: data) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            let read = try file.readData(offset: 1, length: 2)
            XCTAssertEqual(read, Data([0x02, 0x03]))
        }
    }

    func testWriteData() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.writeData(Data([0xAA, 0xBB]), at: 1)
            file.sync()

            let reread = try Data(contentsOf: url)
            XCTAssertEqual(reread, Data([0x00, 0xAA, 0xBB, 0x00]))
        }
    }
}

extension MemoryMappedFileTests {
    func testReadOutOfBounds() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.readData(offset: 3, length: 2)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testWriteNotWritable() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.writeData(Data([1]), at: 0)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .notWritable)
            }
        }
    }

    func testReadTypedNegativeOffset() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.read(offset: -1, as: UInt32.self)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testWriteTypedNegativeOffset() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            XCTAssertThrowsError(
                try file.write(UInt32(0), at: -1)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testSliceWriteTypedNegativeOffset() throws {
        try withTemporaryFile(size: 16) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            let slice = try file.fileSlice(offset: 4, length: 8)
            XCTAssertThrowsError(
                try slice.write(UInt32(0), at: -1)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testReadDataOverflowingOffset() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.readData(offset: .max, length: 1)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testReadTypedOverflowingOffset() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.read(offset: .max, as: UInt32.self)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testWriteEmptyData() throws {
        let initial = Data([1, 2, 3, 4])
        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.writeData(Data(), at: 2)
            file.sync()
            XCTAssertEqual(try Data(contentsOf: url), initial)
        }
    }

    func testInsertEmptyData() throws {
        let initial = Data([1, 2, 3, 4])
        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.insertData(Data(), at: 2)
            file.sync()
            XCTAssertEqual(file.size, initial.count)
            XCTAssertEqual(try Data(contentsOf: url), initial)
        }
    }
}

extension MemoryMappedFileTests {
    func testResizeGrow() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.resize(newSize: 8)
            XCTAssertEqual(file.size, 8)

            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, 8)
        }
    }

    func testInsertData() throws {
        let initial = Data([1, 2, 3, 4])

        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.insertData(Data([9, 9]), at: 2)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 2, 9, 9, 3, 4]))
        }
    }

    func testDeleteData() throws {
        let initial = Data([1, 2, 3, 4, 5])

        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.delete(offset: 1, length: 2)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 4, 5]))
        }
    }
}

extension MemoryMappedFileTests {
    func testTypedReadWrite() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)

            try file.write(UInt32(0xDEADBEEF), at: 0)
            let value: UInt32 = try file.read(offset: 0)

            XCTAssertEqual(value, 0xDEADBEEF)
        }
    }
}

extension MemoryMappedFileTests {
    func testFileSliceReadWrite() throws {
        let data = Data([1, 2, 3, 4, 5, 6])

        try withTemporaryFile(size: data.count, contents: data) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            let slice = try file.fileSlice(offset: 2, length: 3)

            let read = try slice.readData(offset: 0, length: 3)
            XCTAssertEqual(read, Data([3, 4, 5]))

            try slice.writeData(Data([9, 9]), at: 1)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 2, 3, 9, 9, 6]))
        }
    }

    func testSliceInsert() throws {
        let initial = Data([1, 2, 3, 4])

        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            let slice = try file.fileSlice(offset: 1, length: 2)

            try slice.insertData(Data([9]), at: 1)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 2, 9, 3, 4]))
        }
    }
}

extension MemoryMappedFileTests {
    /// A single mapping is contiguous to the end of the file, so the default
    /// implementation on `_SingleMemoryMappedFileIOProtocol` should say so.
    func testUnsafeRegionSpansRestOfFile() throws {
        let data = Data([1, 2, 3, 4, 5, 6, 7, 8])
        try withTemporaryFile(size: data.count, contents: data) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: false)

            let whole = try file.unsafeRegion(at: 0)
            XCTAssertEqual(whole.count, 8)
            XCTAssertEqual(whole.pointer, file.ptr)

            let tail = try file.unsafeRegion(at: 5)
            XCTAssertEqual(tail.count, 3)
            XCTAssertEqual(tail.pointer.load(as: UInt8.self), 6)

            for offset in [8, 9, -1] {
                XCTAssertThrowsError(
                    try file.unsafeRegion(at: offset), "\(offset)"
                ) { error in
                    XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
                }
            }
        }
    }

    /// Generic code over `_MemoryMappedFileIOProtocol` must work for both a
    /// single mapping and a segmented one.
    func testUnsafeRegionThroughProtocol() throws {
        func firstByte(of file: some _MemoryMappedFileIOProtocol) throws -> UInt8 {
            try file.unsafeRegion(at: 0).pointer.load(as: UInt8.self)
        }

        try withTemporaryFiles(
            files: [(size: 4, contents: Data([0xAA, 0, 0, 0]))]
        ) { urls in
            let single = try MemoryMappedFile.open(url: urls[0], isWritable: false)
            let concatenated = try ConcatenatedMemoryMappedFile.open(
                urls: urls,
                isWritable: false
            )
            XCTAssertEqual(try firstByte(of: single), 0xAA)
            XCTAssertEqual(try firstByte(of: concatenated), 0xAA)

            // Both must reject `offset == size` the same way.
            for file in [single as any _MemoryMappedFileIOProtocol, concatenated] {
                XCTAssertThrowsError(try file.unsafeRegion(at: 4)) { error in
                    XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
                }
            }
        }
    }
}

extension MemoryMappedFileTests {
    /// The Windows branch uses `_wsopen_s` rather than the narrow form
    /// specifically so the active code page cannot mangle the path. Nothing
    /// exercised that while every fixture name was an ASCII UUID.
    func testOpenPathWithNonASCIIName() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("ファイル-日本語-\(UUID().uuidString)")
        let contents = Data([0x11, 0x22, 0x33, 0x44])
        guard FileManager.default.createFile(atPath: url.path, contents: contents) else {
            throw XCTSkip("could not create \(url.lastPathComponent)")
        }
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try MemoryMappedFile.open(url: url, isWritable: false)
        XCTAssertEqual(file.size, contents.count)
        XCTAssertEqual(try file.readAllData(), contents)
    }

    /// Deleting everything resizes to zero, which cannot be mapped on any
    /// platform. The instance has to stay usable rather than keep a pointer
    /// to the view it just released.
    func testDeleteEntireContents() throws {
        let initial = Data([1, 2, 3, 4])
        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            try file.delete(offset: 0, length: initial.count)

            XCTAssertEqual(file.size, 0)
            XCTAssertEqual(try file.readAllData(), Data())
            XCTAssertEqual(try Data(contentsOf: url), Data())
            XCTAssertThrowsError(try file.read(offset: 0, as: UInt8.self)) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    /// An empty file starts with the placeholder pointer; growing it must
    /// take on a real mapping, and shrinking back must return to a valid
    /// empty state.
    func testResizeFromAndToEmpty() throws {
        try withTemporaryFile(size: 0) { url in
            let file = try MemoryMappedFile.open(url: url, isWritable: true)
            XCTAssertEqual(file.size, 0)

            try file.resize(newSize: 4)
            XCTAssertEqual(file.size, 4)
            try file.writeData(Data([9, 8, 7, 6]), at: 0)
            file.sync()
            XCTAssertEqual(try Data(contentsOf: url), Data([9, 8, 7, 6]))

            try file.resize(newSize: 0)
            XCTAssertEqual(file.size, 0)
            XCTAssertEqual(try Data(contentsOf: url), Data())
        }
    }
}

