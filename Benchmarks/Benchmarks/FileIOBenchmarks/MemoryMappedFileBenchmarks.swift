import Benchmark
import Foundation
import FileIO

func registerMemoryMappedFileBenchmarks() {
    Benchmark("MemoryMappedFile.open") { benchmark in
        let dir = BenchmarkFixtures.makeTempDirectory()
        defer { BenchmarkFixtures.cleanup(dir) }
        let url = dir.appendingPathComponent("file.bin")
        BenchmarkFixtures.makeFile(at: url, size: BenchmarkFixtures.defaultFileSize)

        benchmark.startMeasurement()

        for _ in benchmark.scaledIterations {
            let file = try MemoryMappedFile.open(url: url, isWritable: false)
            blackHole(file)
        }
    }

    Benchmark("MemoryMappedFile.readData") { benchmark in
        let dir = BenchmarkFixtures.makeTempDirectory()
        defer { BenchmarkFixtures.cleanup(dir) }
        let url = dir.appendingPathComponent("file.bin")
        BenchmarkFixtures.makeFile(at: url, size: BenchmarkFixtures.defaultFileSize)
        let file = try MemoryMappedFile.open(url: url, isWritable: false)
        let ranges = BenchmarkFixtures.readRanges(
            size: file.size,
            length: 4 * 1024,
            count: 1_000
        )

        benchmark.startMeasurement()

        for range in ranges {
            blackHole(try file.readData(offset: range.offset, length: range.length))
        }
    }

    Benchmark("MemoryMappedFile.read.UInt64") { benchmark in
        let dir = BenchmarkFixtures.makeTempDirectory()
        defer { BenchmarkFixtures.cleanup(dir) }
        let url = dir.appendingPathComponent("file.bin")
        BenchmarkFixtures.makeFile(at: url, size: BenchmarkFixtures.defaultFileSize)
        let file = try MemoryMappedFile.open(url: url, isWritable: false)
        let offsets = BenchmarkFixtures.typedOffsets(
            size: file.size,
            as: UInt64.self,
            count: 100_000
        )

        benchmark.startMeasurement()

        for offset in offsets {
            blackHole(try file.read(offset: offset, as: UInt64.self))
        }
    }

    Benchmark("MemoryMappedFile.readAllData") { benchmark in
        let dir = BenchmarkFixtures.makeTempDirectory()
        defer { BenchmarkFixtures.cleanup(dir) }
        let url = dir.appendingPathComponent("file.bin")
        BenchmarkFixtures.makeFile(at: url, size: BenchmarkFixtures.defaultFileSize)
        let file = try MemoryMappedFile.open(url: url, isWritable: false)

        benchmark.startMeasurement()

        for _ in benchmark.scaledIterations {
            blackHole(try file.readAllData())
        }
    }

    Benchmark("MemoryMappedFile.fileSlice.readData") { benchmark in
        let dir = BenchmarkFixtures.makeTempDirectory()
        defer { BenchmarkFixtures.cleanup(dir) }
        let url = dir.appendingPathComponent("file.bin")
        BenchmarkFixtures.makeFile(at: url, size: BenchmarkFixtures.defaultFileSize)
        let file = try MemoryMappedFile.open(url: url, isWritable: false)
        let sliceLength = file.size / 2
        let slice = try file.fileSlice(offset: file.size / 4, length: sliceLength)
        let ranges = BenchmarkFixtures.readRanges(
            size: sliceLength,
            length: 4 * 1024,
            count: 1_000
        )

        benchmark.startMeasurement()

        for range in ranges {
            blackHole(try slice.readData(offset: range.offset, length: range.length))
        }
    }
}
