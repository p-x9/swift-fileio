//
//  system.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/12
//
//

import Foundation

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

// The two-argument `open` overload, module-qualified to pick it out of the
// variadic one. Deliberately not named `_open`: on Windows that collides with
// the MSVC CRT's own variadic `_open`, which Swift cannot import at all
// ("Variadic function is unavailable").
#if canImport(Darwin)
private let _systemOpen = Darwin.open(_:_:)
#elseif canImport(Glibc)
private let _systemOpen = Glibc.open(_:_:)
#elseif canImport(Musl)
private let _systemOpen = Musl.open(_:_:)
#elseif canImport(WASILibc)
private let _systemOpen = WASILibc.open(_:_:)
#elseif canImport(Android)
private let _systemOpen = Android.open(_:_:)
#endif

/// Opens `url` and returns its file descriptor.
///
/// The `open` call is centralized here so that a platform whose `open`
/// differs -- Windows, whose CRT `_open` is variadic and cannot be imported
/// -- needs a branch in this file and nowhere else.
///
/// Deliberately still goes through `url.path`. Reading the file system
/// representation instead is tempting, but every route to it is worse:
/// `withUnsafeFileSystemRepresentation` yields nil on Darwin and *traps* on
/// corelibs Foundation, and `NSURL.getFileSystemRepresentation` relies on a
/// `URL`-to-`NSURL` cast that later Apple platforms break. `url.path` also
/// keeps `errno` meaningful on every failure, because `open` always runs.
///
/// - Throws: `FileIOError.system` carrying the platform error number.
internal func _openFileDescriptor(
    at url: URL,
    isWritable: Bool
) throws -> Int32 {
    let flags = isWritable ? O_RDWR : O_RDONLY
    let fd = _systemOpen(url.path, flags)
    guard _fastPath(fd >= 0) else {
        // Read while errno still belongs to the open call above.
        throw _currentSystemError()
    }
    return fd
}

/// Maps `length` bytes of `fileDescriptor` from its start, shared with the
/// file so that writes reach it, returning `nil` on failure.
///
/// Takes no protection or flag arguments on purpose: those are POSIX shapes
/// that a non-POSIX mapping API cannot express, and leaking them into call
/// sites is what forces every caller to be POSIX-only.
///
/// On Android `mmap` returns a non-optional pointer, where `guard let` does
/// not compile, and `MAP_FAILED` is `((void *) -1)`, a pointer cast Swift
/// cannot import -- so the sentinel is rebuilt from its bit pattern.
internal func _memoryMap(
    fileDescriptor: Int32,
    length: Int,
    isWritable: Bool
) -> UnsafeMutableRawPointer? {
    var protection: Int32 = PROT_READ
    if isWritable { protection |= PROT_WRITE }

    let mapFailed = UnsafeMutableRawPointer(bitPattern: -1)
    let result: UnsafeMutableRawPointer? = mmap(
        nil, length, protection, MAP_SHARED, fileDescriptor, 0
    )
    guard let result, _fastPath(result != mapFailed) else { return nil }
    return result
}

/// Releases a mapping made by ``_memoryMap(fileDescriptor:length:isWritable:)``.
internal func _memoryUnmap(_ pointer: UnsafeMutableRawPointer, length: Int) {
    munmap(pointer, length)
}

/// Flushes `length` bytes of mapped memory at `pointer` to the file.
///
/// `@inlinable` because most callers are themselves `@inlinable`, and an
/// `@inlinable` body cannot reference a plain `internal` declaration.
@inlinable @inline(__always)
internal func _memorySync(_ pointer: UnsafeMutableRawPointer, length: Int) {
    msync(pointer, length, MS_SYNC)
}

/// Sets the length of `fileDescriptor`, reporting whether it succeeded.
internal func _resizeFile(_ fileDescriptor: Int32, to newSize: Int) -> Bool {
    ftruncate(fileDescriptor, off_t(newSize)) == 0
}

/// The platform's current error number, as an error.
///
/// Every read of `errno` in this module goes through here. That matters
/// beyond tidiness: on Android `errno` is a macro (`#define errno
/// (*__errno())`) that Swift cannot import, and Foundation there does not
/// re-export libc the way it does on Darwin and Glibc, so reading it from
/// arbitrary files does not compile.
internal func _currentSystemError() -> FileIOError {
    .system(code: errno)
}
