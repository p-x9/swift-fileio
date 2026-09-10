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

/// `mmap`, returning `nil` instead of the platform's failure sentinel.
///
/// Platforms disagree twice about how failure is reported, and both
/// disagreements are papered over here:
///
/// - The result is an implicitly unwrapped optional on Darwin and Glibc, but
///   non-optional on Android, where `guard let` does not compile.
/// - `MAP_FAILED` is `((void *) -1)` on Android, a pointer cast Swift's
///   importer cannot bring across, so the sentinel is rebuilt from its bit
///   pattern rather than referenced by name.
///
/// Every `mmap` call in this module sits in a non-inlinable function, so this
/// does not need to be `@inlinable`.
internal func _memoryMap(
    _ address: UnsafeMutableRawPointer?,
    _ length: Int,
    _ protection: Int32,
    _ flags: Int32,
    _ fileDescriptor: Int32,
    _ offset: off_t
) -> UnsafeMutableRawPointer? {
    let mapFailed = UnsafeMutableRawPointer(bitPattern: -1)
    let result: UnsafeMutableRawPointer? = mmap(
        address, length, protection, flags, fileDescriptor, offset
    )
    guard let result, _fastPath(result != mapFailed) else { return nil }
    return result
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
