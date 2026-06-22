import Benchmark
import Foundation
import FileIO

enum BenchmarkFixtures {
    /// Default fixture size in bytes (8 MiB; multiple of 16 KiB page size).
    static let defaultFileSize: Int = 8 * 1024 * 1024

    /// Default segment size for concatenated fixtures (2 MiB; multiple of 16 KiB page size).
    static let defaultSegmentSize: Int = 2 * 1024 * 1024

    /// Returns a unique temporary directory rooted under `NSTemporaryDirectory()`.
    static func makeTempDirectory() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-fileio-benchmarks", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func cleanup(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Creates a fixture file on disk filled with a deterministic pattern.
    static func makeFile(
        at url: URL,
        size: Int
    ) {
        let manager = FileManager.default
        try? manager.removeItem(at: url)
        manager.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            fatalError("Failed to create fixture file at \(url.path)")
        }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var chunk = Data(count: chunkSize)
        chunk.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            for i in 0..<chunkSize {
                base.advanced(by: i).storeBytes(of: UInt8(i & 0xff), as: UInt8.self)
            }
        }

        var written = 0
        while written < size {
            let remaining = size - written
            if remaining >= chunkSize {
                handle.write(chunk)
                written += chunkSize
            } else {
                handle.write(chunk.prefix(remaining))
                written += remaining
            }
        }
    }

    /// Creates `count` fixture files of identical `size` in a fresh temp directory.
    /// Returns the directory and the URLs of the created files.
    static func makeConcatenatedFixture(
        count: Int,
        size: Int
    ) -> (directory: URL, urls: [URL]) {
        let dir = makeTempDirectory()
        var urls: [URL] = []
        urls.reserveCapacity(count)
        for i in 0..<count {
            let url = dir.appendingPathComponent("segment_\(i).bin")
            makeFile(at: url, size: size)
            urls.append(url)
        }
        return (dir, urls)
    }

    /// Returns a deterministic list of `(offset, length)` pairs that fit within `size`.
    static func readRanges(
        size: Int,
        length: Int,
        count: Int
    ) -> [(offset: Int, length: Int)] {
        guard size > length, count > 0 else { return [] }
        let span = size - length
        let stride = max(span / count, 1)
        return (0..<count).map { i in
            (offset: (i * stride) % span, length: length)
        }
    }

    /// Returns a deterministic list of offsets aligned for `T`-sized reads within `size`.
    static func typedOffsets<T>(
        size: Int,
        as type: T.Type,
        count: Int
    ) -> [Int] {
        let length = MemoryLayout<T>.size
        guard size > length, count > 0 else { return [] }
        let span = size - length
        let alignment = max(MemoryLayout<T>.alignment, 1)
        let stride = max(span / count, alignment)
        return (0..<count).map { i in
            let raw = (i * stride) % span
            return raw - (raw % alignment)
        }
    }
}
