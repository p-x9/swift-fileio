// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

public enum FileIOError: Error {
    case offsetOutOfBounds
    case notWritable
}

public protocol _FileIOProtocol {
    var size: Int { get }

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

public protocol _MemoryMappedFileIOProtocol: _FileIOProtocol {
    var ptr: UnsafeMutableRawPointer { get }
}

public protocol MemoryMappedFileIOProtocol: _MemoryMappedFileIOProtocol, FileIOProtocol {}

public protocol _StreamedFileIOProtocol: _FileIOProtocol {}
public protocol StreamedFileIOProtocol: _StreamedFileIOProtocol, FileIOProtocol {}

extension _FileIOProtocol {
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
        let size = min(count, size - offset)
        return try readData(offset: offset, length: size)
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
