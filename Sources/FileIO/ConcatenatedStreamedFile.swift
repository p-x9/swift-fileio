//
//  ConcatenatedStreamedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/13
//  
//

import Foundation

public final class ConcatenatedStreamedFile: StreamedFileIOProtocol {
    public struct File {
        public let offset: Int
        public let size: Int
        public let _file: StreamedFile
    }

    public let size: Int
    public let isWritable: Bool

    public let _files: [File]

    private init(
        size: Int,
        isWritable: Bool,
        files: [File]
    ) {
        self.size = size
        self.isWritable = isWritable
        self._files = files
    }
}

extension ConcatenatedStreamedFile {
    public static func open(url: URL, isWritable: Bool) throws -> ConcatenatedStreamedFile {
        try open(urls: [url], isWritable: isWritable)
    }

    public static func open(
        urls: [URL],
        isWritable: Bool
    ) throws -> ConcatenatedStreamedFile {
        var files: [File] = []
        var fullSize: Int = 0
        for url in urls {
            let file: StreamedFile = try .open(url: url, isWritable: isWritable)
            files.append(.init(offset: fullSize, size: file.size, _file: file))
            fullSize += file.size
        }
        return .init(
            size: fullSize,
            isWritable: isWritable,
            files: files
        )
    }
}

extension ConcatenatedStreamedFile {
    @inlinable @inline(__always)
    public func _file(for offset: Int) throws -> File {
        guard let file = _files.first(
            where: { $0.offset <= offset && offset < $0.offset + $0.size }
        ) else {
            throw FileIOError.offsetOutOfBounds
        }
        return file
    }
}

extension ConcatenatedStreamedFile {
    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        var remaining = length
        var currentOffset = offset
        var result = Data()

        while remaining > 0 {
            let file = try _file(for: currentOffset)
            let localOffset = currentOffset - file.offset
            let readable = min(remaining, file.size - localOffset)

            let chunk = try file._file.readData(offset: localOffset, length: readable)
            result.append(chunk)

            currentOffset += readable
            remaining -= readable
        }
        return result
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, offset + data.count <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        var remaining = data.count
        var currentOffset = offset
        var written = 0

        while remaining > 0 {
            let file = try _file(for: currentOffset)
            let localOffset = currentOffset - file.offset
            let writable = min(remaining, file.size - localOffset)

            let slice = data.subdata(in: written ..< written + writable)
            try file._file.writeData(slice, at: localOffset)

            written += writable
            currentOffset += writable
            remaining -= writable
        }
    }

    @inlinable @inline(__always)
    public func sync() {
        _files.forEach { $0._file.sync() }
    }
}

extension ConcatenatedStreamedFile {
    @_disfavoredOverload
    @inlinable @inline(__always)
    public func read<T>(offset: Int) throws -> T {
        try read(offset: offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func read<T>(offset: Int) throws -> Optional<T> {
        try read(offset: offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func read<T>(offset: Int, as: T.Type) throws -> T {
        let length = MemoryLayout<T>.size
        let data = try readData(offset: offset, length: length)
        return data.withUnsafeBytes {
            $0.load(as: T.self)
        }
    }

    @inlinable @inline(__always)
    public func write<T>(_ value: T, at offset: Int) throws {
        let data = withUnsafeBytes(of: value, {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        })
        try self.writeData(data, at: offset)
    }
}

extension ConcatenatedStreamedFile {
    public typealias FileSlice = StreamedFileSlice<ConcatenatedStreamedFile>

    public func fileSlice(
        offset: Int,
        length: Int
    ) throws -> FileSlice {
        guard _fastPath(offset >= 0),
              _fastPath(length >= 0),
              _fastPath(offset + length <= size) else {
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

    /// Creates a `FileSlice` representing a portion of the file.
    ///
    /// - Parameters:
    ///   - offset: The starting position of the slice within the file.
    ///   - length: The size of the slice in bytes.
    ///   - mode: The mode of operation for the slice (`.direct` or `.buffered`).
    /// - Returns: A `FileSlice` that provides access to the specified portion of the file.
    /// - Throws: `FileIOError.offsetOutOfBounds` if the specified range is invalid.
    public func fileSlice(
        offset: Int,
        length: Int,
        mode: FileSlice.Mode
    ) throws -> FileSlice {
        guard _fastPath(offset >= 0),
              _fastPath(length >= 0),
              _fastPath(offset + length <= size) else {
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
