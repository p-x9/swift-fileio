//
//  StreamedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/02/14
//
//

import Foundation

public final class StreamedFile: StreamedFileIOProtocol {
    @_spi(Core)
    public let fileHandle: FileHandle
    public var size: Int {
        return numericCast(fileHandle.seekToEndOfFile())
    }
    public private(set) var generation: Int = 0

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
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        fileHandle.seek(toFileOffset: UInt64(offset))
        return fileHandle.readData(ofLength: Int(length))
    }

    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: count, in: size)) else {
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
        if #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) {
            try? fileHandle.synchronize()
        } else {
            fileHandle.synchronizeFile()
        }
    }
}

extension StreamedFile: ResizableFileIOProtocol {
    public func resize(newSize: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(newSize >= 0) else { return }
        // `insertData` and `delete` both reach here with the current size when
        // asked to move nothing. Bumping there would invalidate every slice
        // over a no-op.
        guard newSize != size else { return }
        generation &+= 1
        fileHandle.truncateFile(atOffset: UInt64(newSize))
    }

    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: 0, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        guard data.count > 0 else { return }

        let remainingData = try readData(offset: offset, length: Int(size) - offset)
        try resize(newSize: size + numericCast(data.count))

        try writeData(remainingData, at: offset + data.count)

        try writeData(data, at: offset)
    }

    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        guard length > 0 else { return }

        // Bumped before the tail moves rather than leaving it to `resize`
        // below: the shifting write can fail having already moved part of the
        // tail, and slices taken beforehand are wrong either way.
        generation &+= 1

        let tailData = try readData(offset: offset + length, length: Int(size) - (offset + length))
        try writeData(tailData, at: offset)

        try resize(newSize: Int(size) - length)
    }
}

extension StreamedFile {
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

extension StreamedFile {
    public typealias FileSlice = StreamedFileSlice<StreamedFile>

    public func fileSlice(
        offset: Int,
        length: Int
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
        offset: Int,
        length: Int,
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

/// A view into part of a ``StreamedFile``.
public final class StreamedFileSlice<Parent: StreamedFileIOProtocol>: FileIOSiliceProtocol, _StreamedFileIOProtocol {
    /// Mode of operation for `StreamedFileSlice`.
    public enum Mode {
        /// Reads and writes are performed directly on the underlying file.
        case direct
        /// Reads and writes operate on an in-memory buffer, requiring synchronization with the file.
        case buffered
    }

    public let parent: Parent

    public private(set) var baseOffset: Int
    public private(set) var size: Int

    public let isWritable: Bool

    public let mode: Mode

    @_spi(Core)
    public private(set) var buffer: Data?

    /// The parent's generation when this slice was made.
    @usableFromInline
    internal let parentGeneration: Int

    /// The file's generation, not the default zero: a slice is only ever as
    /// current as the file it came from.
    @inlinable
    public var generation: Int { parent.generation }

    /// Whether the parent still holds the bytes this slice was made from.
    ///
    /// Once this is false the only remedy is to take a new slice: in
    /// `.buffered` mode the slice is holding a copy of bytes that have since
    /// moved, and there is nothing recording where they went.
    @inlinable @inline(__always)
    public var isValid: Bool {
        parent.generation == parentGeneration
    }

    init(
        parent: Parent,
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
        self.parentGeneration = parent.generation

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
        guard _fastPath(isValid) else { throw FileIOError.staleSlice }
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
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
        guard _fastPath(isValid) else { throw FileIOError.staleSlice }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: count, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        switch mode {
        case .direct:
            try parent.writeData(data, at: baseOffset + offset)
        case .buffered:
            buffer?.replaceSubrange(offset..<offset + count, with: data)
        }
    }

    /// A stale slice flushes nothing. In `.buffered` mode that matters: the
    /// buffer holds bytes that have since moved, so writing it back at the
    /// old offset would overwrite whatever took their place. `sync()` cannot
    /// throw, so this is silent.
    public func sync() {
        guard _fastPath(isValid) else { return }
        switch mode {
        case .direct:
            parent.sync()
        case .buffered:
            guard let buffer else { return }
            try? parent.writeData(buffer, at: baseOffset)
        }
    }

    /// Refreshes the buffer by reloading data from the parent file.
    ///
    /// - Note: This method only applies when the slice is in `.buffered` mode.
    /// - Note: Does nothing once the slice is stale. Rereading would load
    ///   whatever now sits at the old offsets, which is not a refreshed view
    ///   of the same bytes.
    public func refresh() {
        guard mode == .buffered, _fastPath(isValid) else { return }

        let buffer = try? parent.readData(
            offset: baseOffset,
            length: size
        )
        guard let buffer else { return }
        self.buffer = buffer
    }
}

extension StreamedFileSlice {
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
        guard isWritable else { throw FileIOError.notWritable }
        let data = withUnsafeBytes(of: value, {
            Data(buffer: $0.assumingMemoryBound(to: UInt8.self))
        })
        try self.writeData(data, at: offset)
    }
}
