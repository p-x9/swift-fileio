//
//  MemoryMappedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/02/14
//
//

import Foundation

// Foundation re-exports libc on Darwin and Glibc but not on Android, so the
// unqualified libc names below need this.
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

public final class MemoryMappedFile: MemoryMappedFileIOProtocol, _SingleMemoryMappedFileIOProtocol {
    @_spi(Core)
    public var fileDescriptor: Int32
    public private(set) var ptr: UnsafeMutableRawPointer
    public private(set) var size: Int

    public let isWritable: Bool

    internal init(
        fileDescriptor: Int32,
        ptr: UnsafeMutableRawPointer,
        size: Int,
        isWritable: Bool
    ) {
        self.fileDescriptor = fileDescriptor
        self.ptr = ptr
        self.size = size
        self.isWritable = isWritable
    }

    deinit {
        unmap()
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }
}

extension MemoryMappedFile {
    public static func open(url: URL, isWritable: Bool) throws -> MemoryMappedFile {
        let fd = try _openFileDescriptor(at: url, isWritable: isWritable)

        let fileSize = _fileSize(fd)
        guard _fastPath(fileSize >= 0) else {
            close(fd)
            throw _currentSystemError()
        }

        guard _fastPath(fileSize > 0) else {
            return .init(
                fileDescriptor: fd,
                ptr: emptyPlaceholder(),
                size: 0,
                isWritable: isWritable
            )
        }

        // A file can be longer than the address space can describe -- 32-bit
        // targets such as wasm32 cap out well below what a 64-bit filesystem
        // reports.
        guard let length = Int(exactly: fileSize) else {
            close(fd)
            throw FileIOError.system(code: EOVERFLOW)
        }

        let ptr: UnsafeMutableRawPointer
        do {
            ptr = try _memoryMap(
                fileDescriptor: fd,
                length: length,
                isWritable: isWritable
            )
        } catch {
            close(fd)
            throw error
        }

        return .init(
            fileDescriptor: fd,
            ptr: ptr,
            size: length,
            isWritable: isWritable
        )
    }
}

extension MemoryMappedFile {
    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        return Data(bytes: ptr.advanced(by: offset), count: length)
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: count, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        guard count > 0 else { return }
        data.withUnsafeBytes { buffer in
            memcpy(ptr.advanced(by: offset), buffer.baseAddress!, count)
            _memorySync(ptr.advanced(by: offset), length: count)
        }
    }

    @inlinable @inline(__always)
    public func sync() {
        _memorySync(ptr, length: size)
    }

    /// `size == 0` means `ptr` is the placeholder from
    /// ``emptyPlaceholder()``, not a mapping -- zero-length regions cannot be
    /// mapped on any platform. Unmapping it would not release it.
    internal func unmap() {
        if size > 0 {
            _memoryUnmap(ptr, length: size)
        } else {
            ptr.deallocate()
        }
    }

    /// Stand-in pointer for a file with nothing to map.
    internal static func emptyPlaceholder() -> UnsafeMutableRawPointer {
        .allocate(byteCount: 0, alignment: 1)
    }
}

extension MemoryMappedFile: ResizableFileIOProtocol {
    /// Changes the length of the file and remaps it.
    ///
    /// - Note: On failure the instance reports a size of zero and must not be
    ///   used again -- reopen the file instead. Whether the length on disk
    ///   changed is not knowable from here: `ftruncate` can be interrupted
    ///   mid-execution and growing writes zeros, so the previous mapping is
    ///   not restored. Mapping the old length over a file that is no longer
    ///   that long would read past the end, which faults rather than throws.
    public func resize(newSize: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(newSize >= 0) else { return }

        // Unmap before resizing: Windows refuses to shrink a file that still
        // has a view open on it, with EACCES. POSIX does not mind the order.
        unmap()

        // Nothing is mapped from here on, so record that before anything can
        // throw. Otherwise a failure below would leave `ptr` addressing the
        // released view, and deinit would unmap it a second time.
        self.ptr = Self.emptyPlaceholder()
        self.size = 0

        guard _resizeFile(fileDescriptor, to: newSize) else {
            throw _currentSystemError()
        }
        guard newSize > 0 else { return }

        let mapped = try _memoryMap(
            fileDescriptor: fileDescriptor,
            length: newSize,
            isWritable: isWritable
        )
        self.ptr.deallocate()
        self.ptr = mapped
        self.size = newSize
    }

    @inlinable @inline(__always)
    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: 0, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        let count = data.count
        guard count > 0 else { return }

        let newSize = size + count
        try resize(newSize: newSize)

        let tailSize = size - offset - count
        memmove(ptr.advanced(by: offset + count), ptr.advanced(by: offset), tailSize)

        data.withUnsafeBytes { buffer in
            memcpy(ptr.advanced(by: offset), buffer.baseAddress!, count)
            _memorySync(ptr.advanced(by: offset), length: count + tailSize)
        }
    }

    @inlinable @inline(__always)
    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        let tailOffset = offset + length
        let tailSize = size - tailOffset
        memmove(ptr.advanced(by: offset), ptr.advanced(by: tailOffset), tailSize)

        let newSize = size - length
        try resize(newSize: newSize) // sync
    }
}

extension MemoryMappedFile {
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
        return ptr.advanced(by: offset)
            .assumingMemoryBound(to: T.self)
            .pointee
    }

    @inlinable @inline(__always)
    public func write<T>(_ value: T, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let length = MemoryLayout<T>.size
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        ptr.advanced(by: offset)
            .assumingMemoryBound(to: T.self)
            .pointee = value
        _memorySync(ptr.advanced(by: offset), length: length)
    }
}

extension MemoryMappedFile {
    public typealias FileSlice = MemoryMappedFileSlice<MemoryMappedFile>

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

/// A view into part of a ``MemoryMappedFile``.
public class MemoryMappedFileSlice<Parent: MemoryMappedFileIOProtocol & _SingleMemoryMappedFileIOProtocol>: FileIOSiliceProtocol, _SingleMemoryMappedFileIOProtocol {
    public let parent: Parent

    public private(set) var baseOffset: Int
    public private(set) var size: Int

    public let isWritable: Bool

    init(
        parent: Parent,
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

extension MemoryMappedFileSlice {
    /// - Warning: Not revalidated against the parent. A slice keeps the
    ///   `baseOffset` it was made with, so if the parent has been resized
    ///   since, this addresses memory the parent no longer maps. Use
    ///   ``unsafeRegion(at:)``, which checks and reports how far the run
    ///   extends.
    @inlinable @inline(__always)
    public var ptr: UnsafeMutableRawPointer {
        parent.ptr.advanced(by: baseOffset)
    }

    /// The run is bounded by the parent's current size as well as by the end
    /// of this slice, so a slice left outside a shrunk parent throws here
    /// rather than handing back a pointer into nothing.
    @inlinable @inline(__always)
    public func unsafeRegion(at offset: Int) throws -> UnsafeContiguousRegion {
        guard _fastPath(_isInBounds(offset, length: 1, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        let region = try parent.unsafeRegion(at: baseOffset + offset)
        return .init(
            pointer: region.pointer,
            count: min(region.count, size - offset)
        )
    }

    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        return try parent.readData(
            offset: baseOffset + offset,
            length: length
        )
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        let count = data.count
        guard _fastPath(_isInBounds(offset, length: count, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        try parent.writeData(data, at: baseOffset + offset)
    }

    /// Flushes only the part of this slice the parent still maps, so a slice
    /// left outside a shrunk parent flushes nothing instead of touching
    /// released memory.
    @inlinable @inline(__always)
    public func sync() {
        guard let region = try? unsafeRegion(at: 0) else { return }
        _memorySync(region.pointer, length: region.count)
    }
}

extension MemoryMappedFileSlice {
    @_disfavoredOverload
    @inlinable @inline(__always)
    public func read<T>(offset: Int) throws -> T {
        try read(offset: offset, as: T.self)
    }

    @inlinable @inline(__always)
    public func read<T>(offset: Int) throws -> Optional<T> {
        try read(offset: offset, as: T.self)
    }

    /// Goes through the parent rather than ``ptr``, so the parent's current
    /// size is checked as well as this slice's.
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
