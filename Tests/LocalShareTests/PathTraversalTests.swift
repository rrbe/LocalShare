import XCTest
@testable import LocalShare

// 防目录穿越判据 FileServer.resolveWithinRoot 的直接单测——安全命脉，过去只能隔着 HTTP 验，
// 抽成纯函数后在这里穷举：正常嵌套放行、root 自身放行、../ 与绝对穿越拒、内部 .. 归一化后仍在内
// 放行、指向外部的符号链接拒。relPath 视作已解码（上游 removingPercentEncoding 后才进来）。
final class PathTraversalTests: XCTestCase {
    var root: URL!
    var outside: URL!

    override func setUpWithError() throws {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ls-traversal-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        outside = base.appendingPathComponent("outside")   // root 的兄弟，不在 root 内
        try fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: root.appendingPathComponent("sub/file.txt"))
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())   // 删整个 base
    }

    func testNormalNestedPathAllowed() {
        let r = FileServer.resolveWithinRoot(root, relPath: "sub/file.txt")
        XCTAssertNotNil(r)
        XCTAssertTrue(r!.path.hasSuffix("/root/sub/file.txt"))
    }

    func testRootItselfAllowed() {
        XCTAssertNotNil(FileServer.resolveWithinRoot(root, relPath: ""))
    }

    func testInternalDotDotStaysInside() {
        // sub/../sub/file.txt 归一化后仍是 root/sub/file.txt，不是穿越，应放行
        XCTAssertNotNil(FileServer.resolveWithinRoot(root, relPath: "sub/../sub/file.txt"))
    }

    func testDotDotEscapeRejected() {
        XCTAssertNil(FileServer.resolveWithinRoot(root, relPath: ".."))
        XCTAssertNil(FileServer.resolveWithinRoot(root, relPath: "../outside/secret.txt"))
        XCTAssertNil(FileServer.resolveWithinRoot(root, relPath: "sub/../../outside/secret.txt"))
    }

    func testSymlinkEscapeRejected() throws {
        // root 内放一个指向 root 外的符号链接，resolvingSymlinksInPath 解析后逃逸，应拒
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(FileServer.resolveWithinRoot(root, relPath: "escape/secret.txt"))
    }
}
