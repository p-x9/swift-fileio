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
    public var size: UInt64 {
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
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        fileHandle.seek(toFileOffset: UInt64(offset))
        return fileHandle.readData(ofLength: Int(length))
    }

    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, offset + data.count <= size else {
            throw FileIOError.offsetOutOfBounds
        }
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

extension StreamedFile {
    public func read<T>(offset: Int) throws -> T {
        let length = MemoryLayout<T>.size
        let data = try readData(offset: offset, length: length)
        return data.withUnsafeBytes {
            $0.load(as: T.self)
        }
    }

    public func write<T>(_ value: T, at offset: Int) throws {
        let data = withUnsafeBytes(of: value, {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        })
        try self.writeData(data, at: offset)
    }
}

extension StreamedFile {
    public typealias FileSlice = StreamedFileSlice

    public func fileSlice(
        offset: Int,
        length: Int
    ) throws -> FileSlice {
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        return try .init(
            parent: self,
            baseOffset: offset,
            size: length,
            isWritable: isWritable,
            mode: .buffered
        )
    }

    public func fileSlice(
        offset: Int,
        length: Int,
        mode: StreamedFileSlice.Mode
    ) throws -> FileSlice {
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        return try .init(
            parent: self,
            baseOffset: offset,
            size: length,
            isWritable: isWritable,
            mode: mode
        )
    }
}

public class StreamedFileSlice: FileIOSiliceProtocol {
    public enum Mode {
        case direct
        case buffered
    }

    public let parent: StreamedFile

    public private(set) var baseOffset: Int
    public private(set) var size: Int

    public let isWritable: Bool

    public let mode: Mode
    private var buffer: Data?

    init(
        parent: StreamedFile,
        baseOffset: Int,
        size: Int,
        isWritable: Bool,
        mode: Mode
    ) throws {
        self.parent = parent
        self.baseOffset = baseOffset
        self.size = size
        self.isWritable = isWritable
        self.mode = mode

        if mode == .buffered {
            self.buffer = try parent.readData(
                offset: baseOffset,
                length: size
            )
        }
    }
}

extension StreamedFileSlice {
    public func readData(offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        switch mode {
        case .direct:
            return try parent.readData(
                offset: baseOffset + offset,
                length: length
            )
        case .buffered:
            guard let buffer else { throw FileIOError.offsetOutOfBounds }
            return buffer.subdata(in: offset..<offset + length)
        }
    }

    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, offset + data.count <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        switch mode {
        case .direct:
            try parent.writeData(data, at: baseOffset + offset)
        case .buffered:
            buffer?.replaceSubrange(offset..<offset + data.count, with: data)
        }
    }

    public func sync() {
        switch mode {
        case .direct:
            parent.sync()
        case .buffered:
            guard let buffer else { return }
            try? parent.writeData(buffer, at: baseOffset)
        }
    }

    public func refresh() {
        guard mode == .buffered else { return }

        let buffer = try? parent.readData(
            offset: baseOffset,
            length: size
        )
        guard let buffer else { return }
        self.buffer = buffer
    }

    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0 && offset <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        try parent.insertData(data, at: baseOffset + offset)
        self.size += data.count

        if mode == .buffered {
            buffer?.insert(contentsOf: data, at: offset)
        }
    }

    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        try parent.delete(offset: baseOffset + offset, length: length)
        self.size -= length

        if mode == .buffered {
            buffer?.removeSubrange(offset ..< offset + length)
        }
    }

    public func read<T>(offset: Int) throws -> T {
        let length = MemoryLayout<T>.size
        let data = try readData(offset: offset, length: length)
        return data.withUnsafeBytes {
            $0.load(as: T.self)
        }
    }

    public func write<T>(_ value: T, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let data = withUnsafeBytes(of: value, {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        })
        try self.writeData(data, at: offset)
    }
}
