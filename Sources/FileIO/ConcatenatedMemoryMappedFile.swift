//
//  ConcatenatedMemoryMappedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/12
//
//

import Foundation

/// Treats several memory-mapped files as one continuous logical file.
///
/// The files are *logically* contiguous, not physically: each is mapped
/// independently and the concatenation is resolved per access. Nothing here
/// assumes the segments land next to each other in the address space, which
/// is what lets this type work on platforms with no equivalent of overlaying
/// a fixed address range.
///
/// The consequence for callers is that there is no whole-file pointer. Use
/// ``readData(offset:length:)`` and friends, or ``unsafePointer(at:)`` when a
/// zero-copy read matters -- the latter reports how far the contiguous run
/// extends, and reading past it is undefined.
public final class ConcatenatedMemoryMappedFile: FileIOProtocol {
    public struct FileSegment {
        public let offset: Int
        public let size: Int
        public let _file: MemoryMappedFile
    }

    public private(set) var size: Int

    public let isWritable: Bool

    public let _files: [FileSegment]

    private init(
        size: Int,
        isWritable: Bool,
        files: [FileSegment]
    ) {
        self.size = size
        self.isWritable = isWritable
        self._files = files
    }
}

extension ConcatenatedMemoryMappedFile {
    public static func open(url: URL, isWritable: Bool) throws -> ConcatenatedMemoryMappedFile {
        try open(urls: [url], isWritable: isWritable)
    }

    /// Opens `urls` and presents them as one continuous file, in order.
    ///
    /// Each file is mapped on its own, so there is no constraint on the
    /// individual sizes. Empty files are accepted and simply contribute
    /// nothing.
    ///
    /// On failure the segments opened so far are released -- and unmapped and
    /// closed by their own deinit -- as the partially built array goes away.
    public static func open(
        urls: [URL],
        isWritable: Bool
    ) throws -> ConcatenatedMemoryMappedFile {
        var files: [FileSegment] = []
        var fullSize = 0
        for url in urls {
            let file = try MemoryMappedFile.open(url: url, isWritable: isWritable)
            files.append(
                .init(offset: fullSize, size: file.size, _file: file)
            )
            fullSize += file.size
        }
        return .init(
            size: fullSize,
            isWritable: isWritable,
            files: files
        )
    }
}

extension ConcatenatedMemoryMappedFile {
    @inlinable @inline(__always)
    public func _file(for offset: Int) throws -> FileSegment {
        guard let file = _files.first(
            where: { _isInBounds(offset &- $0.offset, length: 1, in: $0.size) }
        ) else {
            throw FileIOError.offsetOutOfBounds
        }
        return file
    }

    /// A pointer to the byte at `offset`, and how many bytes stay contiguous
    /// from there.
    ///
    /// The segments are mapped separately, so a logical range can span two
    /// mappings that are nowhere near each other. `contiguousCount` is the
    /// only safe extent: reading or writing beyond it walks off the end of
    /// one mapping into memory that has nothing to do with this file.
    ///
    /// - Throws: `FileIOError.offsetOutOfBounds` if `offset` is not within
    ///   the file.
    @inlinable @inline(__always)
    public func unsafePointer(
        at offset: Int
    ) throws -> (pointer: UnsafeMutableRawPointer, contiguousCount: Int) {
        let segment = try _file(for: offset)
        let localOffset = offset - segment.offset
        return (
            segment._file.ptr.advanced(by: localOffset),
            segment.size - localOffset
        )
    }
}

// Must support reading and writing of boundaries between files.
extension ConcatenatedMemoryMappedFile {
    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        guard length > 0 else { return Data() }

        let segment = try _file(for: offset)
        let localOffset = offset - segment.offset
        if _fastPath(length <= segment.size - localOffset) {
            return try segment._file.readData(offset: localOffset, length: length)
        }

        var result = Data(capacity: length)
        var remaining = length
        var currentOffset = offset

        while remaining > 0 {
            let segment = try _file(for: currentOffset)
            let localOffset = currentOffset - segment.offset
            let readable = min(remaining, segment.size - localOffset)

            result.append(
                try segment._file.readData(offset: localOffset, length: readable)
            )

            currentOffset += readable
            remaining -= readable
        }
        return result
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: count, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        guard count > 0 else { return }

        let segment = try _file(for: offset)
        let localOffset = offset - segment.offset
        if _fastPath(count <= segment.size - localOffset) {
            try segment._file.writeData(data, at: localOffset)
            return
        }

        var remaining = count
        var currentOffset = offset
        var written = 0

        while remaining > 0 {
            let segment = try _file(for: currentOffset)
            let localOffset = currentOffset - segment.offset
            let writable = min(remaining, segment.size - localOffset)

            try segment._file.writeData(
                data.subdata(in: written ..< written + writable),
                at: localOffset
            )

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

extension ConcatenatedMemoryMappedFile {
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
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        let segment = try _file(for: offset)
        let localOffset = offset - segment.offset
        if _fastPath(length <= segment.size - localOffset) {
            return try segment._file.read(offset: localOffset, as: T.self)
        }

        // Straddles a seam, so the bytes are not contiguous in memory and
        // cannot be loaded through a single pointer.
        return try readData(offset: offset, length: length).withUnsafeBytes {
            $0.loadUnaligned(as: T.self)
        }
    }

    @inlinable @inline(__always)
    public func write<T>(_ value: T, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let length = MemoryLayout<T>.size
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        let segment = try _file(for: offset)
        let localOffset = offset - segment.offset
        if _fastPath(length <= segment.size - localOffset) {
            try segment._file.write(value, at: localOffset)
            return
        }

        let data = withUnsafeBytes(of: value) {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        }
        try writeData(data, at: offset)
    }
}

extension ConcatenatedMemoryMappedFile {
    public typealias FileSlice = ConcatenatedMemoryMappedFileSlice

    public func fileSlice(
        offset: Int,
        length: Int
    ) throws -> FileSlice {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        return .init(
            parent: self,
            baseOffset: offset,
            size: length,
            isWritable: isWritable
        )
    }
}

/// A view into part of a ``ConcatenatedMemoryMappedFile``.
///
/// Unlike ``MemoryMappedFileSlice`` this cannot be a pointer plus an offset,
/// because the parent has no single mapping to offset into. Everything is
/// delegated to the parent, which resolves the segment per access.
public final class ConcatenatedMemoryMappedFileSlice: FileIOSiliceProtocol {
    public let parent: ConcatenatedMemoryMappedFile

    public private(set) var baseOffset: Int
    public private(set) var size: Int

    public let isWritable: Bool

    init(
        parent: ConcatenatedMemoryMappedFile,
        baseOffset: Int,
        size: Int,
        isWritable: Bool
    ) {
        self.parent = parent
        self.baseOffset = baseOffset
        self.size = size
        self.isWritable = isWritable
    }
}

extension ConcatenatedMemoryMappedFileSlice {
    /// See ``ConcatenatedMemoryMappedFile/unsafePointer(at:)`` -- the
    /// contiguous run is still bounded by the parent's segments, and is
    /// additionally clamped to the end of this slice.
    @inlinable @inline(__always)
    public func unsafePointer(
        at offset: Int
    ) throws -> (pointer: UnsafeMutableRawPointer, contiguousCount: Int) {
        guard _fastPath(_isInBounds(offset, length: 1, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        let (pointer, contiguousCount) = try parent.unsafePointer(
            at: baseOffset + offset
        )
        return (pointer, min(contiguousCount, size - offset))
    }

    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        return try parent.readData(offset: baseOffset + offset, length: length)
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: data.count, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        try parent.writeData(data, at: baseOffset + offset)
    }

    @inlinable @inline(__always)
    public func sync() {
        parent.sync()
    }
}

extension ConcatenatedMemoryMappedFileSlice {
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
        guard _fastPath(
            _isInBounds(offset, length: MemoryLayout<T>.size, in: size)
        ) else {
            throw FileIOError.offsetOutOfBounds
        }
        return try parent.read(offset: baseOffset + offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func write<T>(_ value: T, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(
            _isInBounds(offset, length: MemoryLayout<T>.size, in: size)
        ) else {
            throw FileIOError.offsetOutOfBounds
        }
        try parent.write(value, at: baseOffset + offset)
    }
}
