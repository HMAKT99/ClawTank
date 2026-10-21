import XCTest
@testable import ClawTank

final class TransferPathsTests: XCTestCase {
    func testRejectsTraversalAndNormalizes() {
        XCTAssertEqual(TransferPaths.sanitize("photos/cat.jpg"), "photos/cat.jpg")
        XCTAssertEqual(TransferPaths.sanitize("photos\\2026\\cat.jpg"), "photos/2026/cat.jpg", "Windows separators")
        XCTAssertEqual(TransferPaths.sanitize("/etc/passwd"), "etc/passwd", "absolute becomes relative")
        XCTAssertEqual(TransferPaths.sanitize("a:b.txt"), "a-b.txt", "colons are unsafe in Finder names")
        XCTAssertNil(TransferPaths.sanitize("../../.ssh/authorized_keys"))
        XCTAssertNil(TransferPaths.sanitize("photos\\..\\..\\x"))
        XCTAssertNil(TransferPaths.sanitize("."))
        XCTAssertNil(TransferPaths.sanitize(""))
    }
}

final class LocalFileListTests: XCTestCase {
    func testFlattensFoldersAndServesRanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawtank-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("project")
        let src = folder.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try Data("hello world".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("abc".utf8).write(to: folder.appendingPathComponent("src/main.c"))
        let single = root.appendingPathComponent("single.bin")
        try Data([1, 2, 3, 4, 5]).write(to: single)

        let list = LocalFileList.build(from: [folder, single])
        XCTAssertEqual(list.entries.map(\.path), ["project", "project/README.txt", "project/src", "project/src/main.c",
                                                  "single.bin"])
        XCTAssertEqual(list.entries.map(\.isDirectory), [true, false, true, false, false])
        XCTAssertEqual(list.entries[1].size, 11)

        XCTAssertEqual(list.answer(index: 1, query: .size), .size(11))
        XCTAssertEqual(list.answer(index: 1, query: .range(position: 6, length: 5)), .data(Data("world".utf8)))
        XCTAssertEqual(list.answer(index: 4, query: .range(position: 3, length: 10)), .data(Data([4, 5])), "short read")
        XCTAssertEqual(list.answer(index: 0, query: .size), .error, "folders have no contents")
        XCTAssertEqual(list.answer(index: 99, query: .size), .error)
    }
}

final class FileEventDecodingTests: XCTestCase {
    func testDecodesFilesAndRequests() {
        let files = RdpServer.decodeFiles("10\t0\treport.pdf\n0\t1\tphotos\n5\t0\tphotos/cat.jpg")
        XCTAssertEqual(files, [.init(path: "report.pdf", size: 10, isDirectory: false),
                               .init(path: "photos", size: 0, isDirectory: true),
                               .init(path: "photos/cat.jpg", size: 5, isDirectory: false)])
        XCTAssertEqual(RdpServer.decodeFileRequest("7\t2\tsize"),
                       .clipboardFileRequested(stream: 7, index: 2, query: .size))
        XCTAssertEqual(RdpServer.decodeFileRequest("8\t2\trange\t100\t4096"),
                       .clipboardFileRequested(stream: 8, index: 2, query: .range(position: 100, length: 4096)))
        XCTAssertNil(RdpServer.decodeFileRequest("garbage"))
    }
}
