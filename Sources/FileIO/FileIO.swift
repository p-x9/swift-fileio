// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

public enum FileIOError: Error, Equatable {
    case offsetOutOfBounds
    case notWritable

    /// The slice was made before its file changed length. Take the slice
    /// again from the resized file.
    ///
    /// Thrown for every slice made before the change, not only those whose
    /// bytes actually moved -- appending past the end of a slice invalidates
    /// it too. Narrowing that would mean recording which ranges each mutation
    /// shifted, and nothing does.
    ///
    /// Distinct from ``offsetOutOfBounds`` because the range can still be
    /// perfectly valid: inserting ahead of a slice leaves it in bounds and
    /// pointing at somebody else's bytes, which is the case that reads as a
    /// plausible answer rather than as an error.
    case staleSlice

    /// A platform call failed. `code` is an `errno` value, on every platform
    /// -- including Windows, whose CRT entry points report that way.
    ///
    /// Replaces the `POSIXError` this module used to throw. `POSIXError` was
    /// constructed as `POSIXError(.init(rawValue: errno)!)`, which traps for
    /// any error number Foundation does not model, and it ties the thrown
    /// type to Foundation on platforms where that is not a given.
    case system(code: Int32)

    /// A Win32 call failed. `code` is a `GetLastError` value.
    ///
    /// Separate from ``system(code:)`` because the two numbering schemes
    /// overlap without agreeing: 5 is `EIO` as an `errno` and
    /// `ERROR_ACCESS_DENIED` as a Win32 error. Normalizing one into the other
    /// would need a hand-written table that collapses codes with no
    /// counterpart, so the domain is kept instead of the information lost.
    ///
    /// Only thrown on Windows, but declared everywhere so that a `switch`
    /// over this type is the same on every platform.
    case windows(code: UInt32)
}

extension FileIOError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .offsetOutOfBounds: "offset out of bounds"
        case .notWritable: "file is not writable"
        case .staleSlice: "slice was made before the file was resized"
        case .system(let code): "system error \(code)"
        case .windows(let code): "Win32 error \(code)"
        }
    }
}

/// Single-comparison bounds check that rejects negative `offset`/`length`
/// and any `offset + length` that would exceed `size`, without going through
/// signed overflow that could trap. Negative `Int` becomes a huge `UInt`
/// via `bitPattern`, so it fails the `<= size` comparison naturally.
/// `size` is assumed non-negative.
@usableFromInline
@inlinable
@inline(__always)
internal func _isInBounds(_ offset: Int, length: Int, in size: Int) -> Bool {
    let usize = UInt(bitPattern: size)
    return UInt(bitPattern: offset) <= usize
        && UInt(bitPattern: length) <= usize &- UInt(bitPattern: offset)
}

public protocol _FileIOProtocol {
    var size: Int { get }

    /// Changes whenever an operation moves the bytes that offsets into this
    /// file address. A slice records it when it is made and refuses to work
    /// once it differs, because its offsets then describe other bytes.
    ///
    /// - Important: The default implementation returns a constant, which is
    ///   only correct for a type that never moves its bytes. A type that also
    ///   conforms to ``ResizableFileIOProtocol`` must implement this and
    ///   change it before each mutation begins; leaving the default in place
    ///   makes every slice it hands out claim to be current forever. Swift
    ///   cannot withhold the default from those conformers, so this is a
    ///   contract rather than something the compiler checks.
    var generation: Int { get }

    /// Whether this still describes the bytes it was made from.
    ///
    /// Always true for a whole file, which is its own reference. A slice
    /// holds a ``FileIOSiliceProtocol/baseOffset``, which describes a
    /// position, so a mutation that moves bytes leaves it addressing someone
    /// else's. Rather than work out which slices that applies to, any change
    /// of length invalidates all of them -- including a slice whose own bytes
    /// did not move. A resize to the length the file already has changes
    /// nothing and invalidates nothing.
    ///
    /// A slice cannot be adjusted, because nothing records where the bytes
    /// went; take a new one from the file instead.
    ///
    /// Declared here rather than on ``FileIOSiliceProtocol`` so that the
    /// shared implementations below can check it. They are extension methods
    /// rather than requirements, so a version added further down the
    /// hierarchy would be bypassed by anything holding an
    /// ``_FileIOProtocol``.
    var isValid: Bool { get }

    /// Reads a specified range of bytes from the file.
    ///
    /// - Parameters:
    ///   - offset: The starting position of the data to read.
    ///   - length: The number of bytes to read.
    /// - Returns: A `Data` object containing the read bytes.
    /// - Throws: `FileIOError.offsetOutOfBounds` if the specified range is invalid.
    func readData(offset: Int, length: Int) throws -> Data

    /// Writes data to the file at the specified offset.
    ///
    /// - Parameters:
    ///   - data: The data to write.
    ///   - offset: The position in the file where the data should be written.
    /// - Throws:
    ///   - `FileIOError.notWritable` if the file is not writable.
    ///   - `FileIOError.offsetOutOfBounds` if the offset is invalid.
    func writeData(_ data: Data, at offset: Int) throws

    /// Ensures that any pending data modifications are written to the file.
    func sync()

    func read<T>(offset: Int) throws -> T
    func read<T>(offset: Int, as: T.Type) throws -> T
    func write<T>(_ value: T, at offset: Int) throws
}

public protocol FileIOProtocol: _FileIOProtocol {
    associatedtype FileSlice: FileIOSiliceProtocol

    /// Opens a file at the specified URL.
    ///
    /// - Parameters:
    ///   - url: The file URL to open.
    ///   - isWritable: A boolean indicating whether the file should be opened for writing.
    /// - Returns: An instance of `Self` for file operations.
    /// - Throws: An error if the file cannot be opened.
    static func open(url: URL, isWritable: Bool) throws -> Self

    /// Creates a `FileSlice` representing a portion of the file.
    ///
    /// - Parameters:
    ///   - offset: The starting position of the slice within the file.
    ///   - length: The size of the slice in bytes.
    /// - Returns: A `FileSlice` that provides access to the specified portion of the file.
    /// - Throws: `FileIOError.offsetOutOfBounds` if the specified range is invalid.
    func fileSlice(offset: Int, length: Int) throws -> FileSlice
}

public protocol FileIOSiliceProtocol: _FileIOProtocol {
    var baseOffset: Int { get }
}

/// - Important: A conformer must implement ``_FileIOProtocol/generation`` and
///   change it before each of these operations starts moving bytes. Slices
///   taken beforehand describe positions whose contents have moved, and that
///   is the only signal they have.
public protocol ResizableFileIOProtocol: _FileIOProtocol {
    /// Inserts data into the file at the specified offset, shifting existing data.
    ///
    /// - Parameters:
    ///   - data: The data to insert.
    ///   - offset: The position in the file where the data should be inserted.
    /// - Throws:
    ///   - `FileIOError.notWritable` if the file is not writable.
    ///   - `FileIOError.offsetOutOfBounds` if the offset is invalid.
    func insertData(_ data: Data, at offset: Int) throws

    /// Deletes a specified range of bytes from the file, shifting remaining data.
    ///
    /// - Parameters:
    ///   - offset: The starting position of the data to delete.
    ///   - length: The number of bytes to remove.
    /// - Throws:
    ///   - `FileIOError.notWritable` if the file is not writable.
    ///   - `FileIOError.offsetOutOfBounds` if the specified range is invalid.
    func delete(offset: Int, length: Int) throws
}

/// A run of bytes that is contiguous in memory, and how far it extends.
///
/// A memory-mapped file is not necessarily one mapping:
/// `ConcatenatedMemoryMappedFile` maps each of its files separately, so a
/// logical range can span two mappings that sit nowhere near each other.
/// `count` is the extent that is actually safe to touch from `pointer`.
///
/// A struct rather than a tuple because this is a protocol requirement, and a
/// tuple could not gain a field later without breaking every conformance.
public struct UnsafeContiguousRegion {
    /// The first byte of the run.
    public let pointer: UnsafeMutableRawPointer

    /// How many bytes stay contiguous from ``pointer``. Reading or writing
    /// beyond this leaves the mapping.
    public let count: Int

    @inlinable
    public init(pointer: UnsafeMutableRawPointer, count: Int) {
        self.pointer = pointer
        self.count = count
    }

    /// The run as a buffer, which is the bounds-carrying way to consume it.
    @inlinable
    public var buffer: UnsafeMutableRawBufferPointer {
        .init(start: pointer, count: count)
    }
}

public protocol _MemoryMappedFileIOProtocol: _FileIOProtocol {
    /// The contiguous run of mapped memory starting at `offset`.
    ///
    /// - Throws: `FileIOError.offsetOutOfBounds` if `offset` is not within
    ///   the file.
    func unsafeRegion(at offset: Int) throws -> UnsafeContiguousRegion
}

/// A mapping that is backed by a single contiguous region, and so can offer a
/// base pointer for the whole file.
///
/// `ConcatenatedMemoryMappedFile` deliberately does not adopt this: it holds
/// one mapping per file and has no such pointer. Anything that only needs to
/// read mapped bytes should take ``_MemoryMappedFileIOProtocol`` instead, so
/// that it works with both.
public protocol _SingleMemoryMappedFileIOProtocol: _MemoryMappedFileIOProtocol {
    var ptr: UnsafeMutableRawPointer { get }
}

extension _SingleMemoryMappedFileIOProtocol {
    @inlinable @inline(__always)
    public func unsafeRegion(at offset: Int) throws -> UnsafeContiguousRegion {
        guard _fastPath(_isInBounds(offset, length: 1, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        return .init(pointer: ptr.advanced(by: offset), count: size - offset)
    }
}

public protocol MemoryMappedFileIOProtocol: _MemoryMappedFileIOProtocol, FileIOProtocol {}

public protocol _StreamedFileIOProtocol: _FileIOProtocol {}
public protocol StreamedFileIOProtocol: _StreamedFileIOProtocol, FileIOProtocol {}

extension _FileIOProtocol {
    /// A file that cannot be resized never moves its bytes, so nothing taken
    /// from it goes stale. See the requirement for what a resizable conformer
    /// owes instead.
    @inlinable
    public var generation: Int { 0 }

    /// Only a slice can fall behind the file it came from.
    @inlinable
    public var isValid: Bool { true }

    /// Reads up to a specified number of bytes from the file, starting at a given offset.
    ///
    /// - Parameters:
    ///   - offset: The starting position of the data to read.
    ///   - count: The maximum number of bytes to read.
    /// - Returns: A `Data` object containing the read bytes.
    /// - Throws: `FileIOError.offsetOutOfBounds` if the specified range is invalid.
    public func readData(
        offset: Int,
        upToCount count: Int
    ) throws -> Data {
        // Ahead of the bounds check, as everywhere else: a stale slice's own
        // `size` is the one it was made with, so an offset can be out of
        // range here for a reason that is not the interesting one. The check
        // cannot be dropped in favour of the delegate's, because `size -
        // offset` below would overflow for a sufficiently negative offset.
        guard _fastPath(isValid) else { throw FileIOError.staleSlice }
        guard _fastPath(_isInBounds(offset, length: 0, in: size)) else {
            throw FileIOError.offsetOutOfBounds
        }
        let length = min(count, size - offset)
        return try readData(offset: offset, length: length)
    }

    /// Reads the entire contents of the file.
    ///
    /// - Returns: A `Data` object containing all bytes in the file, from offset `0`
    ///   up to the current file size.
    /// - Throws: `FileIOError.offsetOutOfBounds` if the file size is invalid or
    ///   cannot be read.
    public func readAllData() throws -> Data {
        try readData(offset: 0, length: size)
    }
}
