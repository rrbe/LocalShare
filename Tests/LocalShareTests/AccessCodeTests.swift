import XCTest
@testable import LocalShare

final class AccessCodeTests: XCTestCase {
    func testGeneratedCodeIsReadableAndNormalized() {
        for _ in 0..<100 {
            let code = AccessCode.generate()
            XCTAssertEqual(code.count, 7)
            XCTAssertEqual(code[code.index(code.startIndex, offsetBy: 3)], "-")
            let normalized = AccessCode.normalize(code)
            XCTAssertEqual(normalized.count, 6)
            XCTAssertFalse(normalized.contains("0"))
            XCTAssertFalse(normalized.contains("O"))
            XCTAssertFalse(normalized.contains("1"))
            XCTAssertFalse(normalized.contains("I"))
        }
    }

    func testNormalizationAcceptsTypingVariations() {
        XCTAssertEqual(AccessCode.normalize("k7m-pq2"), "K7MPQ2")
        XCTAssertEqual(AccessCode.normalize(" K7M PQ2 "), "K7MPQ2")
        XCTAssertEqual(AccessCode.format("k7mpq2"), "K7M-PQ2")
    }

    func testShareTicketModeActionsAreLocalized() {
        XCTAssertEqual(L.useAccessCode(.zh), "改用访问码")
        XCTAssertEqual(L.useFullURL(.zh), "改用完整网址")
        XCTAssertEqual(L.useAccessCode(.en), "Use Access Code")
        XCTAssertEqual(L.useFullURL(.en), "Use Full URL")
    }

    func testJoinPageIsLocalizedAndKeepsCodeOutOfURL() {
        let zh = AccessCodePage.html(lang: .zh, error: .invalid)
        XCTAssertTrue(zh.contains(">LocalShare</div>"))
        XCTAssertTrue(zh.contains("输入访问码"))
        XCTAssertTrue(zh.contains("例如 K7M-PQ2"))
        XCTAssertTrue(zh.contains("访问码不正确"))
        XCTAssertFalse(zh.contains("class=\"sub\""))
        XCTAssertTrue(zh.contains("method=\"post\""))
        XCTAssertFalse(zh.contains("?code="))

        let en = AccessCodePage.html(lang: .en, error: .limited)
        XCTAssertTrue(en.contains("Enter Access Code"))
        XCTAssertTrue(en.contains("Too many attempts"))
    }
}
