import XCTest
@testable import LocalShare

// 访客上传文件名清洗 FileServer.sanitizeFileName 的单测——XSS 去势的第一道闸（过去只由慢吞吞的
// smoke-upload-defang.sh 端到端覆盖）。重点：可执行文档扩展名追加 .txt、只取末段防穿越、隐藏文件
// 与空名拒、控制符剔除、冒号换连字符。
final class SanitizeFileNameTests: XCTestCase {
    func testNilAndEmptyRejected() {
        XCTAssertNil(FileServer.sanitizeFileName(nil))
        XCTAssertNil(FileServer.sanitizeFileName(""))
        XCTAssertNil(FileServer.sanitizeFileName("   "))
    }

    func testNormalNamesUnchanged() {
        XCTAssertEqual(FileServer.sanitizeFileName("report.pdf"), "report.pdf")
        XCTAssertEqual(FileServer.sanitizeFileName("照片 1.jpg"), "照片 1.jpg")   // 中文 + 空格保留
    }

    func testExecutableDocsDefanged() {
        XCTAssertEqual(FileServer.sanitizeFileName("index.html"), "index.html.txt")
        XCTAssertEqual(FileServer.sanitizeFileName("evil.svg"), "evil.svg.txt")
        XCTAssertEqual(FileServer.sanitizeFileName("EVIL.SVG"), "EVIL.SVG.txt")   // 扩展名判定不分大小写
        XCTAssertEqual(FileServer.sanitizeFileName("page.xhtml"), "page.xhtml.txt")
    }

    func testPathStrippedToLastComponent() {
        XCTAssertEqual(FileServer.sanitizeFileName("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileServer.sanitizeFileName("/abs/dir/x.txt"), "x.txt")
        XCTAssertEqual(FileServer.sanitizeFileName("../sneaky/index.html"), "index.html.txt")  // 末段仍去势
    }

    func testHiddenAndDotNamesRejected() {
        XCTAssertNil(FileServer.sanitizeFileName(".hidden"))
        XCTAssertNil(FileServer.sanitizeFileName("."))
        XCTAssertNil(FileServer.sanitizeFileName(".."))
    }

    func testColonReplacedAndControlStripped() {
        XCTAssertEqual(FileServer.sanitizeFileName("a:b.txt"), "a-b.txt")
        XCTAssertEqual(FileServer.sanitizeFileName("a\u{0007}b.txt"), "ab.txt")   // BEL 等控制符剔除
    }
}
