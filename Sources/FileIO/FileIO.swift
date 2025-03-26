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

    /// Resizes the file to the specified new size.
    ///
    /// - Parameter newSize: The new size of the file in bytes.
    /// - Throws: `FileIOError.notWritable` if the file is not writable.
    func resize(newSize: Int) throws

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
}
