//
//  Util.swift
//  swift-fileio
//
//  Created by p-x9 on 2026/01/06
//
//

import Foundation

func withTemporaryFile(
    size: Int,
    contents: Data? = nil,
    _ body: (URL) throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory
    let url = dir.appendingPathComponent(UUID().uuidString)

    FileManager.default.createFile(
        atPath: url.path,
        contents: contents ?? Data(repeating: 0, count: size)
    )

    defer {
        try? FileManager.default.removeItem(at: url)
    }

    try body(url)
}

func withTemporaryFiles(
    files: [(size: Int, contents: Data?)],
    _ body: ([URL]) throws -> Void
) throws {
    let dir = FileManager.default.temporaryDirectory
    let urls = files.map { _ in
        dir.appendingPathComponent(UUID().uuidString)
    }

    for (url, file) in zip(urls, files) {
        FileManager.default.createFile(
            atPath: url.path,
            contents: file.contents ?? Data(repeating: 0, count: file.size)
        )
    }

    defer {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    try body(urls)
}
