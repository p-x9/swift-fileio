// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

public enum FileIOError: Error {
    case offsetOutOfBounds
    case notWritable
}

public protocol _FileIOProtocol {
    func readData(offset: Int, length: Int) throws -> Data
    func writeData(_ data: Data, at offset: Int) throws

    func sync()

    func resize(newSize: Int) throws
    func insertData(_ data: Data, at offset: Int) throws
    func delete(offset: Int, length: Int) throws
}

public protocol FileIOProtocol: _FileIOProtocol {
    associatedtype FileSlice: FileIOSiliceProtocol

    static func open(url: URL, isWritable: Bool) throws -> Self

    func fileSlice(offset: Int, length: Int) throws -> FileSlice
}

public protocol FileIOSiliceProtocol: _FileIOProtocol {
    var baseOffset: Int { get }
}
