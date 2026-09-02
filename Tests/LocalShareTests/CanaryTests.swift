import XCTest
@testable import LocalShare

// 探针：证明可执行 target 能被 @testable import、internal 符号可见、Swifter/Sparkle 链接不挡测试。
// 跑通即说明无须拆 library target；跑不通再考虑分 LocalShareCore。
final class CanaryTests: XCTestCase {
    func testMimeContentType() {
        XCTAssertEqual(Mime.contentType(forExtension: "html"), "text/html; charset=utf-8")
        XCTAssertEqual(Mime.contentType(forExtension: "HTML"), "text/html; charset=utf-8")  // 大小写不敏感
        XCTAssertEqual(Mime.contentType(forExtension: "png"), "image/png")                  // 二进制无 charset
        XCTAssertEqual(Mime.contentType(forExtension: "svg"), "image/svg+xml; charset=utf-8")
        XCTAssertEqual(Mime.contentType(forExtension: "xyz"), "application/octet-stream")   // 未知回退
    }

    func testGeneratedBrowserPagesExposeWideLayout() {
        let csv = CsvViewer.html(fileName: "wide.csv", crumbs: nil, canUpload: false, lang: .zh)
        let listing = DirectoryListing.html(items: [], rootName: "Files", lang: .en)
        for page in [csv, listing] {
            XCTAssertTrue(page.contains("id=\"widebtn\""))
            XCTAssertTrue(page.contains("sessionStorage.getItem('ls-wide')"))
            XCTAssertTrue(page.contains("body.wide main{max-width:none"))
            XCTAssertTrue(page.contains("clamp(24px,4vw,64px)"))
        }
    }

    func testGeneratedBrowserPagesUseConciseCopy() {
        let send = SendText.html(lang: .zh)
        XCTAssertTrue(send.contains("<span>LocalShare</span>"))
        XCTAssertTrue(send.contains("<h1>发送文本</h1>"))
        XCTAssertTrue(send.contains("placeholder=\"输入文本…\""))
        XCTAssertFalse(send.contains("class=\"sub\""))

        let viewer = TextViewer.html(text: "hello", crumbs: nil, canUpload: false, lang: .zh)
        XCTAssertFalse(viewer.contains("class=\"hint\""))

        let empty = DirectoryListing.html(items: [], rootName: "分享内容", lang: .zh)
        XCTAssertTrue(empty.contains("空文件夹"))

        let item = (name: "example.txt", url: URL(fileURLWithPath: "/tmp/example.txt"), isDir: false)
        let listing = DirectoryListing.html(items: [item], rootName: "Files", lang: .en)
        XCTAssertTrue(listing.contains("No matching files"))
        XCTAssertFalse(listing.contains("class=\"nr-s\""))
        XCTAssertTrue(listing.contains("<div class=\"colophon\">LocalShare</div>"))
    }
}
