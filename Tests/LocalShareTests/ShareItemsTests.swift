import XCTest
@testable import LocalShare

// 多选虚拟根的 key 分配 FileServer.Share.makeItems 与上传重名兜底 FileServer.availableURL 的单测。
// 两者都触磁盘（fileExists），故在临时目录里搭真实文件验：key 取 lastPathComponent、重名 -2/-3、
// 不存在的项跳过；上传落点重名同款 -2/-3（含无扩展名分支）。
final class ShareItemsTests: XCTestCase {
    var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ls-items-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    private func touch(_ rel: String) throws -> URL {
        let u = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        return u
    }

    @discardableResult
    private func mkdir(_ rel: String) throws -> URL {
        let u = base.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func testKeysAndDirFlag() throws {
        let f = try touch("a.txt")
        let d = try mkdir("docs")
        let items = FileServer.Share.makeItems([f, d])
        XCTAssertEqual(items.map(\.key), ["a.txt", "docs"])
        XCTAssertEqual(items.map(\.isDir), [false, true])
    }

    func testDedupesCollidingNames() throws {
        let f1 = try touch("dir1/a.txt")
        let f2 = try touch("dir2/a.txt")
        let f3 = try touch("dir3/a.txt")
        let items = FileServer.Share.makeItems([f1, f2, f3])
        XCTAssertEqual(items.map(\.key), ["a.txt", "a-2.txt", "a-3.txt"])
    }

    func testSkipsNonexistent() throws {
        let f = try touch("real.txt")
        let ghost = base.appendingPathComponent("ghost.txt")
        let items = FileServer.Share.makeItems([f, ghost])
        XCTAssertEqual(items.map(\.key), ["real.txt"])
    }

    func testAvailableURLNoCollision() throws {
        let dir = try mkdir("d")
        XCTAssertEqual(FileServer.availableURL(in: dir, name: "x.txt").lastPathComponent, "x.txt")
    }

    func testAvailableURLSuffixesOnCollision() throws {
        let dir = try mkdir("d")
        try Data("x".utf8).write(to: dir.appendingPathComponent("x.txt"))
        XCTAssertEqual(FileServer.availableURL(in: dir, name: "x.txt").lastPathComponent, "x-2.txt")
        try Data("x".utf8).write(to: dir.appendingPathComponent("x-2.txt"))
        XCTAssertEqual(FileServer.availableURL(in: dir, name: "x.txt").lastPathComponent, "x-3.txt")
    }

    func testAvailableURLNoExtension() throws {
        let dir = try mkdir("d")
        try Data("x".utf8).write(to: dir.appendingPathComponent("data"))
        XCTAssertEqual(FileServer.availableURL(in: dir, name: "data").lastPathComponent, "data-2")
    }
}
