//
//  StreamedFileTests.swift
//  swift-fileio
//
//  Created by p-x9 on 2026/01/06
//  
//

import XCTest
@testable import FileIO

final class StreamedFileTests: XCTestCase {}

extension StreamedFileTests {
    func testOpenAndSize() throws {
        try withTemporaryFile(size: 1024) { url in
            let file = try StreamedFile.open(url: url, isWritable: false)
            XCTAssertEqual(file.size, 1024)
        }
    }

    func testOpenEmptyFile() throws {
        try withTemporaryFile(size: 0) { url in
            let file = try StreamedFile.open(url: url, isWritable: false)
            XCTAssertEqual(file.size, 0)
        }
    }
}

extension StreamedFileTests {
    func testReadData() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])

        try withTemporaryFile(size: data.count, contents: data) { url in
            let file = try StreamedFile.open(url: url, isWritable: false)
            let read = try file.readData(offset: 1, length: 2)
            XCTAssertEqual(read, Data([0x02, 0x03]))
        }
    }

    func testWriteData() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)
            try file.writeData(Data([0xAA, 0xBB]), at: 1)
            file.sync()

            let reread = try Data(contentsOf: url)
            XCTAssertEqual(reread, Data([0x00, 0xAA, 0xBB, 0x00]))
        }
    }
}

extension StreamedFileTests {
    func testReadOutOfBounds() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try StreamedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.readData(offset: 3, length: 2)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }

    func testWriteNotWritable() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try StreamedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.writeData(Data([1]), at: 0)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .notWritable)
            }
        }
    }
}

extension StreamedFileTests {
    func testResizeGrow() throws {
        try withTemporaryFile(size: 4) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)
            try file.resize(newSize: 8)
            XCTAssertEqual(file.size, 8)

            let data = try Data(contentsOf: url)
            XCTAssertEqual(data.count, 8)
        }
    }

    func testInsertData() throws {
        let initial = Data([1, 2, 3, 4])

        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)
            try file.insertData(Data([9, 9]), at: 2)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 2, 9, 9, 3, 4]))
        }
    }

    func testDeleteData() throws {
        let initial = Data([1, 2, 3, 4, 5])

        try withTemporaryFile(size: initial.count, contents: initial) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)
            try file.delete(offset: 1, length: 2)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 4, 5]))
        }
    }
}

extension StreamedFileTests {
    func testTypedReadWrite() throws {
        try withTemporaryFile(size: 8) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)

            try file.write(UInt32(0xDEADBEEF), at: 0)
            let value: UInt32 = try file.read(offset: 0)

            XCTAssertEqual(value, 0xDEADBEEF)
        }
    }
}

extension StreamedFileTests {
    func testFileSliceReadWrite() throws {
        let data = Data([1, 2, 3, 4, 5, 6])

        try withTemporaryFile(size: data.count, contents: data) { url in
            let file = try StreamedFile.open(url: url, isWritable: true)
            let slice = try file.fileSlice(
                offset: 2,
                length: 3,
                mode: .direct // not `buffered`
            )

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
            let file = try StreamedFile.open(url: url, isWritable: true)
            let slice = try file.fileSlice(offset: 1, length: 2)

            try slice.insertData(Data([9]), at: 1)

            let result = try Data(contentsOf: url)
            XCTAssertEqual(result, Data([1, 2, 9, 3, 4]))
        }
    }
}
