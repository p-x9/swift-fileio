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

        let fileSize = lseek(fd, 0, SEEK_END)
        guard _fastPath(fileSize >= 0) else {
            close(fd)
            throw _currentSystemError()
        }

        guard _fastPath(fileSize > 0) else {
            return .init(
                fileDescriptor: fd,
                ptr: .allocate(byteCount: 0, alignment: 1),
                size: 0,
                isWritable: isWritable
            )
        }

        let ptr: UnsafeMutableRawPointer
        do {
            ptr = try _memoryMap(
                fileDescriptor: fd,
                length: Int(fileSize),
                isWritable: isWritable
            )
        } catch {
            close(fd)
            throw error
        }

        return .init(
            fileDescriptor: fd,
            ptr: ptr,
            size: Int(fileSize),
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

    internal func unmap() {
        _memoryUnmap(ptr, length: size)
    }
}

extension MemoryMappedFile: ResizableFileIOProtocol {
    public func resize(newSize: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(newSize >= 0) else { return }

        // Unmap before resizing: Windows refuses to shrink a file that still
        // has a view open on it, with EACCES. POSIX does not mind the order.
        unmap()

        guard _resizeFile(fileDescriptor, to: newSize) else {
            throw _currentSystemError()
        }

        let ptr = try _memoryMap(
            fileDescriptor: fileDescriptor,
            length: newSize,
            isWritable: isWritable
        )

        self.ptr = ptr
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
    @inlinable @inline(__always)
    public var ptr: UnsafeMutableRawPointer {
        parent.ptr.advanced(by: baseOffset)
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

    @inlinable @inline(__always)
    public func sync() {
        _memorySync(parent.ptr.advanced(by: baseOffset), length: size)
    }
}

extension MemoryMappedFileSlice: ResizableFileIOProtocol where Parent: ResizableFileIOProtocol {
    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: 0, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        try parent.insertData(data, at: baseOffset + offset)
        self.size += data.count
    }

    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(_isInBounds(offset, length: length, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }

        try parent.delete(offset: baseOffset + offset, length: length)
        self.size -= length
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
