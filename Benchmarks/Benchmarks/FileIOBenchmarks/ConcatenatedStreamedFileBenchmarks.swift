import Benchmark
import Foundation
import FileIO

func registerConcatenatedStreamedFileBenchmarks() {
    Benchmark("ConcatenatedStreamedFile.open") { benchmark in
        let fixture = BenchmarkFixtures.makeConcatenatedFixture(
            count: 4,
            size: BenchmarkFixtures.defaultSegmentSize
        )
        defer { BenchmarkFixtures.cleanup(fixture.directory) }

        benchmark.startMeasurement()

        for _ in benchmark.scaledIterations {
            let file = try ConcatenatedStreamedFile.open(
                urls: fixture.urls,
                isWritable: false
            )
            blackHole(file)
        }
    }

    Benchmark("ConcatenatedStreamedFile.readData") { benchmark in
        let fixture = BenchmarkFixtures.makeConcatenatedFixture(
            count: 4,
            size: BenchmarkFixtures.defaultSegmentSize
        )
        defer { BenchmarkFixtures.cleanup(fixture.directory) }
        let file = try ConcatenatedStreamedFile.open(
            urls: fixture.urls,
            isWritable: false
        )
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

    Benchmark("ConcatenatedStreamedFile.read.UInt64") { benchmark in
        let fixture = BenchmarkFixtures.makeConcatenatedFixture(
            count: 4,
            size: BenchmarkFixtures.defaultSegmentSize
        )
        defer { BenchmarkFixtures.cleanup(fixture.directory) }
        let file = try ConcatenatedStreamedFile.open(
            urls: fixture.urls,
            isWritable: false
        )
        let offsets = BenchmarkFixtures.typedOffsets(
            size: file.size,
            as: UInt64.self,
            count: 10_000
        )

        benchmark.startMeasurement()

        for offset in offsets {
            blackHole(try file.read(offset: offset, as: UInt64.self))
        }
    }
}
