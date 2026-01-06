//
//  ConcatenatedStreamedFileTests.swift
//  swift-fileio
//
//  Created by p-x9 on 2026/01/06
//

import XCTest
@testable import FileIO

final class ConcatenatedStreamedFileTests: XCTestCase {}

extension ConcatenatedStreamedFileTests {
    func testOpenSingleFile() throws {
        try withTemporaryFile(size: 4, contents: Data([1, 2, 3, 4])) { url in
            let file = try ConcatenatedStreamedFile.open(url: url, isWritable: false)
            XCTAssertEqual(file.size, 4)

            let read = try file.readData(offset: 0, length: 4)
            XCTAssertEqual(read, Data([1, 2, 3, 4]))
        }
    }

    func testOpenMultipleFilesAndReadAcrossBoundary() throws {
        try withTemporaryFiles(
            files: [
                (size: 3, contents: Data([1, 2, 3])),
                (size: 3, contents: Data([4, 5, 6]))
            ]
        ) { urls in
            let file = try ConcatenatedStreamedFile.open(
                urls: urls,
                isWritable: false
            )

            XCTAssertEqual(file.size, 6)

            let read = try file.readData(offset: 1, length: 4)
            XCTAssertEqual(read, Data([2, 3, 4, 5]))
        }
    }
}

extension ConcatenatedStreamedFileTests {
    func testWriteAcrossFileBoundary() throws {
        try withTemporaryFiles(
            files: [
                (size: 3, contents: Data([1, 2, 3])),
                (size: 3, contents: Data([4, 5, 6]))
            ]
        ) { urls in
            let file = try ConcatenatedStreamedFile.open(
                urls: [urls[0], urls[1]],
                isWritable: true
            )

            try file.writeData(Data([9, 9, 9, 9]), at: 1)
            file.sync()

            let reread1 = try Data(contentsOf: urls[0])
            let reread2 = try Data(contentsOf: urls[1])

            XCTAssertEqual(reread1, Data([1, 9, 9]))
            XCTAssertEqual(reread2, Data([9, 9, 6]))
        }
    }

    func testWriteNotWritable() throws {
        try withTemporaryFile(size: 2, contents: Data([1, 2])) { url in
            let file = try ConcatenatedStreamedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.writeData(Data([9]), at: 0)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .notWritable)
            }
        }
    }
}

extension ConcatenatedStreamedFileTests {
    func testTypedReadWrite() throws {
        try withTemporaryFiles(
            files: [
                (size: 4, contents: nil),
                (size: 4, contents: nil)
            ]
        ) { urls in
            let file = try ConcatenatedStreamedFile.open(
                urls: [urls[0], urls[1]],
                isWritable: true
            )

            try file.write(UInt32(0xDEADBEEF), at: 2)
            let value: UInt32 = try file.read(offset: 2)

            XCTAssertEqual(value, 0xDEADBEEF)
        }
    }
}

extension ConcatenatedStreamedFileTests {
    func testFileSliceReadWrite() throws {
        try withTemporaryFiles(
            files: [
                (size: 4, contents: Data([1, 2, 3, 4])),
                (size: 4, contents: Data([5, 6, 7, 8]))
            ]
        ) { urls in
            let file = try ConcatenatedStreamedFile.open(
                urls: [urls[0], urls[1]],
                isWritable: true
            )

            let slice = try file.fileSlice(offset: 3, length: 3, mode: .direct)
            let read = try slice.readData(offset: 0, length: 3)
            XCTAssertEqual(read, Data([4, 5, 6]))

            try slice.writeData(Data([9, 9]), at: 1)

            let reread1 = try Data(contentsOf: urls[0])
            let reread2 = try Data(contentsOf: urls[1])

            XCTAssertEqual(reread1, Data([1, 2, 3, 4]))
            XCTAssertEqual(reread2, Data([9, 9, 7, 8]))
        }
    }
}

extension ConcatenatedStreamedFileTests {
    func testReadOutOfBounds() throws {
        try withTemporaryFile(size: 2, contents: Data([1, 2])) { url in
            let file = try ConcatenatedStreamedFile.open(url: url, isWritable: false)
            XCTAssertThrowsError(
                try file.readData(offset: 1, length: 2)
            ) { error in
                XCTAssertEqual(error as? FileIOError, .offsetOutOfBounds)
            }
        }
    }
}
