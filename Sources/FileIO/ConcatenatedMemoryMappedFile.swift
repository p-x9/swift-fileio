//
//  ConcatenatedMemoryMappedFile.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/12
//  
//

import Foundation

public final class ConcatenatedMemoryMappedFile: MemoryMappedFileIOProtocol {
    public private(set) var ptr: UnsafeMutableRawPointer
    public private(set) var size: Int

    public let isWritable: Bool

    public let _files: [MemoryMappedFile]

    private init(
        ptr: UnsafeMutableRawPointer,
        size: Int,
        isWritable: Bool,
        files: [MemoryMappedFile]
    ) {
        self.ptr = ptr
        self.size = size
        self.isWritable = isWritable
        self._files = files
    }
}

extension ConcatenatedMemoryMappedFile {
    public static func open(url: URL, isWritable: Bool) throws -> ConcatenatedMemoryMappedFile {
        try open(urls: [url], isWritable: isWritable)
    }

    public static func open(
        urls: [URL],
        isWritable: Bool
    ) throws -> ConcatenatedMemoryMappedFile {
        var fdAndSizes: [(fd: CInt, size: off_t)] = []
        for url in urls {
            let fd = _open(url.path, isWritable ? O_RDWR : O_RDONLY)
            guard _fastPath(fd > 0) else {
                cleanup(fds: fdAndSizes.map(\.fd))
                throw POSIXError(.init(rawValue: errno)!)
            }

            let fileSize = lseek(fd, 0, SEEK_END)
            guard _fastPath(fileSize > 0) else {
                cleanup(fds: fdAndSizes.map(\.fd))
                close(fd)
                throw POSIXError(.init(rawValue: errno)!)
            }

            fdAndSizes.append((fd, fileSize))
        }

        let fullSize = fdAndSizes.reduce(0, { $0 + $1.size })

        let basePtr = mmap(
            nil,
            numericCast(fullSize),
            PROT_NONE,
            MAP_PRIVATE | MAP_ANONYMOUS,
            -1,
            0
        )
        guard let basePtr,
              _fastPath(basePtr != MAP_FAILED) else {
            cleanup(fds: fdAndSizes.map(\.fd))
            throw POSIXError(.init(rawValue: errno)!)
        }

        var prot: Int32 = PROT_READ
        if isWritable { prot |= PROT_WRITE }

        var offset = 0
        var files: [MemoryMappedFile] = []
        for (fd, size) in fdAndSizes {
            let size: Int = numericCast(size)
            let ptr = basePtr.advanced(by: offset)
            let mappedPtr = mmap(ptr, size, prot, MAP_FIXED | MAP_PRIVATE, fd, 0)
            guard ptr == mappedPtr,
                  _fastPath(ptr != MAP_FAILED) else {
                cleanup(fds: fdAndSizes.map(\.fd))
                throw POSIXError(.init(rawValue: errno)!)
            }
            files.append(
                .init(
                    fileDescriptor: fd,
                    ptr: ptr,
                    size: size,
                    isWritable: isWritable
                )
            )
            offset += size
        }

        return .init(
            ptr: basePtr,
            size: numericCast(fullSize),
            isWritable: isWritable,
            files: files
        )
    }

    private static func cleanup(fds: [CInt]) {
        fds.forEach { close($0) }
    }
}

extension ConcatenatedMemoryMappedFile {
    @inlinable @inline(__always)
    public func readData(offset: Int, length: Int) throws -> Data {
        guard _fastPath(offset >= 0),
              _fastPath(length >= 0),
              _fastPath(offset + length <= size) else {
            throw FileIOError.offsetOutOfBounds
        }
        return Data(bytes: ptr.advanced(by: offset), count: length)
    }

    @inlinable @inline(__always)
    public func writeData(_ data: Data, at offset: Int) throws {
        guard isWritable else { throw FileIOError.notWritable }
        guard _fastPath(offset >= 0),
              _fastPath(offset + data.count <= size) else {
            throw FileIOError.offsetOutOfBounds
        }
        data.withUnsafeBytes { buffer in
            memcpy(ptr.advanced(by: offset), buffer.baseAddress!, data.count)
            msync(ptr.advanced(by: offset), data.count, MS_SYNC)
        }
    }

    @inlinable @inline(__always)
    public func sync() {
        _files.forEach { $0.sync() }
    }

    internal func unmap() {
        _files.forEach { $0.unmap() }
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
        guard _fastPath(offset + length <= size) else {
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
        guard _fastPath(offset + length <= size) else {
            throw FileIOError.offsetOutOfBounds
        }
        ptr.advanced(by: offset)
            .assumingMemoryBound(to: T.self)
            .pointee = value
        msync(ptr.advanced(by: offset), length, MS_SYNC)
    }
}

extension ConcatenatedMemoryMappedFile {
    public typealias FileSlice = MemoryMappedFileSlice<ConcatenatedMemoryMappedFile>

    public func fileSlice(
        offset: Int,
        length: Int
    ) throws -> FileSlice {
        guard _fastPath(offset >= 0),
              _fastPath(length >= 0),
              _fastPath(offset + length <= size) else {
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
