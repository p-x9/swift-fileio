//
//  MemoryMappedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/02/14
//
//

import Foundation

#if canImport(Darwin)
import Darwin
fileprivate let _open = Darwin.open(_:_:)
#elseif canImport(Glibc)
import Glibc
fileprivate let _open = Glibc.open(_:_:)
#elseif canImport(Musl)
import Musl
fileprivate let _open = Musl.open(_:_:)
#elseif canImport(WASILibc)
import WASILibc
fileprivate let _open = WASILibc.open(_:_:)
#elseif canImport(Android)
import Android
fileprivate let _open = Android.open(_:_:)
#endif

public final class MemoryMappedFile: FileIOProtocol {
    private var fileDescriptor: Int32
    public private(set) var ptr: UnsafeMutableRawPointer
    private var size: Int

    public let isWritable: Bool

    private init(
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
        let fd = _open(url.path, isWritable ? O_RDWR : O_RDONLY)
        guard fd > 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        let fileSize = lseek(fd, 0, SEEK_END)
        guard fileSize > 0 else {
            close(fd)
            throw POSIXError(.init(rawValue: errno)!)
        }

        var prot: Int32 = PROT_READ
        if isWritable { prot |= PROT_WRITE }
        let ptr = mmap(nil, Int(fileSize), prot, MAP_SHARED, fd, 0)
        guard let ptr,
              ptr != MAP_FAILED else {
            close(fd)
            throw POSIXError(.init(rawValue: errno)!)
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
    public func readData(offset: Int, length: Int) throws -> Data {
        guard offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        return Data(bytes: ptr.advanced(by: offset), count: length)
    }

    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset + data.count <= size else {
            throw FileIOError.offsetOutOfBounds
        }
        _ = data.withUnsafeBytes { buffer in
            memcpy(ptr.advanced(by: offset), buffer.baseAddress!, data.count)
        }
    }

    public func sync() {
        msync(ptr, size, MS_SYNC)
    }

    private func unmap() {
        munmap(ptr, size)
    }
}

extension MemoryMappedFile {
    public func resize(newSize: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard newSize > 0 else { return }

        guard ftruncate(fileDescriptor, off_t(newSize)) == 0 else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        unmap()

        var prot: Int32 = PROT_READ
        if isWritable { prot |= PROT_WRITE }
        let ptr = mmap(nil, newSize, prot, MAP_SHARED, fileDescriptor, 0)
        guard let ptr,
              ptr != MAP_FAILED else {
            throw POSIXError(.init(rawValue: errno)!)
        }

        self.ptr = ptr
        self.size = newSize
    }

    public func insertData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, offset <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        let newSize = size + data.count
        try resize(newSize: newSize)

        let tailSize = size - offset - data.count
        memmove(ptr.advanced(by: offset + data.count), ptr.advanced(by: offset), tailSize)

        _ = data.withUnsafeBytes { buffer in
            memcpy(ptr.advanced(by: offset), buffer.baseAddress!, data.count)
        }
    }

    public func delete(offset: Int, length: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard offset >= 0, length > 0, offset + length <= size else {
            throw FileIOError.offsetOutOfBounds
        }

        let tailOffset = offset + length
        let tailSize = size - tailOffset
        memmove(ptr.advanced(by: offset), ptr.advanced(by: tailOffset), tailSize)

        let newSize = size - length
        try resize(newSize: newSize)
    }
}
