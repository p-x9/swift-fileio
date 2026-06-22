import Benchmark

let benchmarks: @Sendable () -> Void = {
    registerMemoryMappedFileBenchmarks()
    registerStreamedFileBenchmarks()
    registerConcatenatedMemoryMappedFileBenchmarks()
    registerConcatenatedStreamedFileBenchmarks()
}
