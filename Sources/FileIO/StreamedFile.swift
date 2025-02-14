//
//  StreamedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/02/14
//  
//

import Foundation

public final class StreamedFile: FileIOProtocol {
    private let fileHandle: FileHandle
    private var size: UInt64 {
        return fileHandle.seekToEndOfFile()
    }

    public let isWritable: Bool

    private init(fileHandle: FileHandle, isWritable: Bool) {
        self.fileHandle = fileHandle
        self.isWritable = isWritable
    }

    deinit {
        fileHandle.closeFile()
    }
}

extension StreamedFile {
    public static func open(url: URL, isWritable: Bool) throws -> StreamedFile {
        let fileHandle = if isWritable {
            try FileHandle(forUpdating: url)
        } else {
            try FileHandle(forReadingFrom: url)
        }
        return .init(fileHandle: fileHandle, isWritable: isWritable)
    }
}

extension StreamedFile {
    public func readData(offset: Int, length: Int) throws -> Data {
        fileHandle.seek(toFileOffset: UInt64(offset))
        return fileHandle.readData(ofLength: Int(length))
    }

    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        fileHandle.seek(toFileOffset: UInt64(offset))
        if #available(macOS 10.15.4, iOS 13.4, watchOS 6.2, tvOS 13.4, *) {
            try fileHandle.write(contentsOf: data)
        } else {
            fileHandle.write(data)
        }
    }

    public func sync() {
        if #available(macOS 10.15, *) {
            try? fileHandle.synchronize()
        } else {
            fileHandle.synchronizeFile()
        }
    }
}

extension StreamedFile {
    public func resize(newSize: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard newSize > 0 else { return }
        fileHandle.truncateFile(atOffset: UInt64(newSize))
    }

    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, offset <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        let remainingData = try readData(offset: offset, length: Int(size) - offset)
        try resize(newSize: Int(size + UInt64(data.count)))

        try writeData(remainingData, at: offset + data.count)

        try writeData(data, at: offset)
    }

    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        let tailData = try readData(offset: offset + length, length: Int(size) - (offset + length))
        try writeData(tailData, at: offset)

        try resize(newSize: Int(size) - length)
    }
}
