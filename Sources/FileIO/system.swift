//
//  system.swift
//  swift-fileio
//
//  Created by p-x9 on 2025/07/12
//
//

import Foundation

#if os(Windows)
import ucrt
import WinSDK
#elseif canImport(Darwin)
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

#if !os(Windows)
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
#if os(Windows)
    // `_wsopen_s` rather than `_open`: the latter is variadic, and the wide
    // form avoids the active code page mangling non-ASCII paths. `_O_BINARY`
    // is required or the CRT translates line endings in the mapped bytes.
    let flags = (isWritable ? _O_RDWR : _O_RDONLY) | _O_BINARY
    var fd: Int32 = -1
    var widePath = Array(url.path.utf16)
    widePath.append(0)
    let status = widePath.withUnsafeBufferPointer {
        _wsopen_s(&fd, $0.baseAddress!, flags, _SH_DENYNO, 0)
    }
    guard _fastPath(status == 0), fd >= 0 else {
        throw FileIOError.system(code: status)
    }
    return fd
#else
    let flags = isWritable ? O_RDWR : O_RDONLY
    let fd = _systemOpen(url.path, flags)
    guard _fastPath(fd >= 0) else {
        // Read while errno still belongs to the open call above.
        throw _currentSystemError()
    }
    return fd
#endif
}

/// Maps `length` bytes of `fileDescriptor` from its start, shared with the
/// file so that writes reach it.
///
/// Takes no protection or flag arguments on purpose: those are POSIX shapes
/// that a non-POSIX mapping API cannot express, and leaking them into call
/// sites is what forces every caller to be POSIX-only.
///
/// Throws rather than returning nil so that the error is built next to the
/// call that failed. On Windows that matters: the mapping APIs report through
/// `GetLastError`, leaving `errno` holding something unrelated.
///
/// - Throws: `FileIOError.system` carrying the platform error number.
internal func _memoryMap(
    fileDescriptor: Int32,
    length: Int,
    isWritable: Bool
) throws -> UnsafeMutableRawPointer {
#if os(Windows)
    let handle = HANDLE(bitPattern: _get_osfhandle(fileDescriptor))
    guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw FileIOError.system(code: EBADF)
    }

    // Size 0 maps the whole file. The mapping object can be closed right
    // away: the view keeps it alive.
    guard let mapping = CreateFileMappingW(
        handle,
        nil,
        DWORD(isWritable ? PAGE_READWRITE : PAGE_READONLY),
        0,
        0,
        nil
    ) else {
        throw _lastWindowsError()
    }
    defer { CloseHandle(mapping) }

    let access = DWORD(isWritable ? FILE_MAP_READ | FILE_MAP_WRITE : FILE_MAP_READ)
    guard let view = MapViewOfFile(mapping, access, 0, 0, SIZE_T(length)) else {
        throw _lastWindowsError()
    }
    return view
#else
    var protection: Int32 = PROT_READ
    if isWritable { protection |= PROT_WRITE }

    let mapFailed = UnsafeMutableRawPointer(bitPattern: -1)
    let result: UnsafeMutableRawPointer? = mmap(
        nil, length, protection, MAP_SHARED, fileDescriptor, 0
    )
    guard let result, _fastPath(result != mapFailed) else {
        throw _currentSystemError()
    }
    return result
#endif
}

/// Releases a mapping made by ``_memoryMap(fileDescriptor:length:isWritable:)``.
internal func _memoryUnmap(_ pointer: UnsafeMutableRawPointer, length: Int) {
#if os(Windows)
    UnmapViewOfFile(pointer)
#else
    munmap(pointer, length)
#endif
}

/// Flushes `length` bytes of mapped memory at `pointer` to the file.
///
/// `@inlinable` because most callers are themselves `@inlinable`, and an
/// `@inlinable` body cannot reference a plain `internal` declaration.
@inlinable @inline(__always)
internal func _memorySync(_ pointer: UnsafeMutableRawPointer, length: Int) {
#if os(Windows)
    FlushViewOfFile(pointer, SIZE_T(length))
#else
    msync(pointer, length, MS_SYNC)
#endif
}

/// Sets the length of `fileDescriptor`, reporting whether it succeeded.
internal func _resizeFile(_ fileDescriptor: Int32, to newSize: Int) -> Bool {
#if os(Windows)
    _chsize_s(fileDescriptor, Int64(newSize)) == 0
#else
    ftruncate(fileDescriptor, off_t(newSize)) == 0
#endif
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

#if os(Windows)
/// `GetLastError` as an error, for the Win32 APIs that do not touch `errno`.
///
/// `FileIOError.system(code:)` therefore carries an `errno` value for calls
/// that came through the CRT and a Win32 error code for those that did not.
internal func _lastWindowsError() -> FileIOError {
    .system(code: Int32(bitPattern: GetLastError()))
}
#endif
