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
/// Both platform concerns of opening a file live here: converting a `URL` to
/// the bytes the platform expects, and the `open` call itself.
///
/// The path is taken from the file system representation rather than
/// `url.path`, which loses information for paths that are not valid UTF-8.
///
/// - Throws: `FileIOError.system` carrying the platform error number.
internal func _openFileDescriptor(
    at url: URL,
    isWritable: Bool
) throws -> Int32 {
    let flags = isWritable ? O_RDWR : O_RDONLY
    let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return _systemOpen(path, flags)
    }
    guard _fastPath(fd >= 0) else {
        throw _currentSystemError()
    }
    return fd
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
