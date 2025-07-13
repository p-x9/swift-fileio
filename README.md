# FileIO

A Swift library for reading and writing files.

<!-- # Badges -->

[![Github issues](https://img.shields.io/github/issues/p-x9/swift-fileio)](https://github.com/p-x9/swift-fileio/issues)
[![Github forks](https://img.shields.io/github/forks/p-x9/swift-fileio)](https://github.com/p-x9/swift-fileio/network/members)
[![Github stars](https://img.shields.io/github/stars/p-x9/swift-fileio)](https://github.com/p-x9/swift-fileio/stargazers)
[![Github top language](https://img.shields.io/github/languages/top/p-x9/swift-fileio)](https://github.com/p-x9/swift-fileio/)

## Features

- [MemoryMappedFile](./Sources/FileIO/MemoryMappedFile.swift): using mmap
- [StreamedFile](./Sources/FileIO/StreamedFile.swift): using FileHandle (syscall)

- [ConcatenatedMemoryMappedFile](./Sources/FileIO/ConcatenatedMemoryMappedFile.swift): using mmap. Treats multiple files as one continuous virtual file.
- [StreamedFile](./Sources/FileIO/ConcatenatedStreamedFile.swift): using FileHandle (syscall). Treats multiple files as one continuous virtual file.

## Usage

MemoryMappedFile/StreamedFile have the same API available for both.

Available methods are defined in the [FileIOProtocol](./Sources/FileIO/FileIO.swift)

## License

FileIO is released under the MIT License. See [LICENSE](./LICENSE)
