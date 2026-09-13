import XCTest
@testable import LocalShare

final class MediaDownloadTests: XCTestCase {
    func testByteRanges() {
        XCTAssertEqual(FileServer.byteRange("bytes=0-1", size: 10), 0...1)
        XCTAssertEqual(FileServer.byteRange("bytes=4-", size: 10), 4...9)
        XCTAssertEqual(FileServer.byteRange("bytes=-3", size: 10), 7...9)
        XCTAssertEqual(FileServer.byteRange("bytes=-30", size: 10), 0...9)
        XCTAssertEqual(FileServer.byteRange("bytes=4-99", size: 10), 4...9)
        for invalid in ["bytes=10-", "bytes=5-4", "bytes=-0", "bytes=0-1,4-5", "bytes=a-b", "bytes=0-18446744073709551616"] {
            XCTAssertNil(FileServer.byteRange(invalid, size: 10), invalid)
        }
        XCTAssertNil(FileServer.byteRange("bytes=0-", size: 0))
    }

    func testArchiveContentsAndCleanup() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let name = "中文 100% #?.txt"
        try Data("selected content".utf8).write(to: root.appendingPathComponent(name))
        try Data("unselected".utf8).write(to: root.appendingPathComponent("private.txt"))
        let path = "/" + name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!
        var archive: BatchDownload? = try BatchDownload(paths: [path], share: .directory(root))
        let url = archive!.url
        let output = root.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", url.path, output.path]
        try unzip.run()
        unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: output.path), [name])
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent(name)), "selected content")
        archive = nil
        XCTAssertFalse(fm.fileExists(atPath: url.path))
    }

    func testArchiveRejectsDirectoriesTraversalAndExternalSymlinks() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        try fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: false)
        for path in ["/../etc/hosts", "/%2e%2e/etc/hosts", "/..%2fetc/hosts", "/outside", "/folder"] {
            XCTAssertThrowsError(try BatchDownload(paths: [path], share: .directory(root)), path)
        }
    }

    func testVirtualRootIsolation() {
        let file = URL(fileURLWithPath: "/tmp/original.txt")
        let share = FileServer.Share.multiple([.init(key: "renamed.txt", url: file, isDir: false)])
        XCTAssertEqual(share.fileURL(for: "/renamed.txt"), file.resolvingSymlinksInPath())
        XCTAssertNil(share.fileURL(for: "/original.txt"))
        XCTAssertNil(share.fileURL(for: "/renamed.txt/child"))
        XCTAssertNil(FileServer.Share.file(file).fileURL(for: "/other.txt"))
    }
}
