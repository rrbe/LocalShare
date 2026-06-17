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
}
