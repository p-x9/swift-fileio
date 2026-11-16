//
//  ConcatenatedStreamedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/13
//  
//

import Foundation

public final class ConcatenatedStreamedFile: StreamedFileIOProtocol {
    public struct FileSegment {
        public let offset: Int64
        public let size: Int64
        public let _file: StreamedFile
    }

    public let size: Int64
    public let isWritable: Bool

    public let _files: [FileSegment]

    private init(
        size: Int64,
        isWritable: Bool,
        files: [FileSegment]
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
        var files: [FileSegment] = []
        var fullSize: Int64 = 0
        for url in urls {
            let file: StreamedFile = try .open(url: url, isWritable: isWritable)
            files.append(.init(offset: fullSize, size: file.size, _file: file))
            // Reachable on wasm32, where files can exceed `Int.max` together.
            let (sum, overflow) = fullSize.addingReportingOverflow(file.size)
            guard !overflow else { throw _sizeOverflowError() }
            fullSize = sum
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
    public func _file(for offset: Int64) throws -> FileSegment {
        guard let file = _files.first(
            where: { _isInBounds(offset &- $0.offset, length: 1, in: $0.size) }
        ) else {
            throw FileIOError.offsetOutOfBounds
        }
        return file
    }
}

// Must support reading and writing of boundaries between files.
extension ConcatenatedStreamedFile {
    @inlinable @inline(__always)
    public func readData(offset: Int64, length: Int) throws -> Data {
        guard _fastPath(_isInBounds(offset, length: Int64(length), in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        var remaining = length
        var currentOffset = offset
        var result = Data()

        while remaining > 0 {
            let file = try _file(for: currentOffset)
            let localOffset = currentOffset - file.offset
            let readable = Int(
                truncatingIfNeeded: min(Int64(remaining), file.size - localOffset)
            )

            let chunk = file._file._uncheckedReadData(
                offset: localOffset,
                length: readable
            )
            result.append(chunk)

            currentOffset += Int64(readable)
            remaining -= readable
        }
        return result
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int64) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: Int64(count), in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        var remaining = count
        var currentOffset = offset
        var written = 0

        while remaining > 0 {
            let file = try _file(for: currentOffset)
            let localOffset = currentOffset - file.offset
            let writable = Int(
                truncatingIfNeeded: min(Int64(remaining), file.size - localOffset)
            )

            let slice = data.subdata(in: written ..< written + writable)
            try file._file._uncheckedWriteData(slice, at: localOffset)

            written += writable
            currentOffset += Int64(writable)
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
    public func read<T>(offset: Int64) throws -> T {
        try read(offset: offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func read<T>(offset: Int64) throws -> Optional<T> {
        try read(offset: offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func read<T>(offset: Int64, as: T.Type) throws -> T {
        let length = MemoryLayout<T>.size
        let data = try readData(offset: offset, length: length)
        return data.withUnsafeBytes {
            $0.load(as: T.self)
        }
    }

    @inlinable @inline(__always)
    public func write<T>(_ value: T, at offset: Int64) throws {
        let data = withUnsafeBytes(of: value, {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        })
        try self.writeData(data, at: offset)
    }
}

extension ConcatenatedStreamedFile {
    public typealias FileSlice = StreamedFileSlice<ConcatenatedStreamedFile>

    public func fileSlice(
        offset: Int64,
        length: Int64
    ) throws -> FileSlice {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
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
        offset: Int64,
        length: Int64,
        mode: FileSlice.Mode
    ) throws -> FileSlice {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
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
