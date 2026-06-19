import XCTest
@testable import LocalShare

// i18n 核心单测：Accept-Language 解析、LangPref 解析、L 表覆盖（每个 case 中英都非空）、
// permSummary 双语派生。纯函数，不触磁盘 / 不起服务。
final class LangTests: XCTestCase {

    // MARK: Accept-Language → Lang

    func testAcceptLanguageEnglish() {
        XCTAssertEqual(Lang.fromAcceptLanguage("en-US,en;q=0.9"), .en)
    }

    func testAcceptLanguageChinesePreferred() {
        XCTAssertEqual(Lang.fromAcceptLanguage("zh-CN,zh;q=0.9,en;q=0.8"), .zh)
    }

    func testAcceptLanguageQOrdering() {
        // en 的 q 更高，应胜出（顺序在后也不影响）
        XCTAssertEqual(Lang.fromAcceptLanguage("zh;q=0.6,en;q=0.7"), .en)
        // zh 的 q 更高
        XCTAssertEqual(Lang.fromAcceptLanguage("en;q=0.5,zh;q=0.9"), .zh)
    }

    func testAcceptLanguageSkipsUnknownThenPicks() {
        // 法语不识别，跳过；en 次高 q 命中
        XCTAssertEqual(Lang.fromAcceptLanguage("de,en;q=0.7,zh;q=0.6"), .en)
    }

    func testAcceptLanguageSameQKeepsFirst() {
        // 同 q（缺省 1.0）保留先出现者
        XCTAssertEqual(Lang.fromAcceptLanguage("en,zh"), .en)
        XCTAssertEqual(Lang.fromAcceptLanguage("zh,en"), .zh)
    }

    func testAcceptLanguageFallbackToZh() {
        XCTAssertEqual(Lang.fromAcceptLanguage(nil), .zh)
        XCTAssertEqual(Lang.fromAcceptLanguage(""), .zh)
        XCTAssertEqual(Lang.fromAcceptLanguage("fr-FR,fr"), .zh)
    }

    // MARK: LangPref → Lang

    func testResolveExplicit() {
        XCTAssertEqual(Lang.resolve(.zh), .zh)
        XCTAssertEqual(Lang.resolve(.en), .en)
    }

    func testResolveSystemIsSupported() {
        // .system 解析结果必须是受支持的两种之一（具体取决于运行环境的首选语言）。
        XCTAssertTrue([Lang.zh, .en].contains(Lang.resolve(.system)))
    }

    // MARK: L 表覆盖

    func testEveryKeyHasBothLanguages() {
        // 守住 callAsFunction 的查表：每个 case 中英文都非空（switch 已编译期穷尽，这里防空串/漏填）。
        for key in L.allCases {
            XCTAssertFalse(key(.zh).isEmpty, "L.\(key) 缺中文")
            XCTAssertFalse(key(.en).isEmpty, "L.\(key) 缺英文")
        }
    }

    // MARK: permSummary 双语

    func testPermSummaryReadonly() {
        let zh = permSummary(Permission(), .zh)
        XCTAssertEqual(zh.tag, "只读")
        XCTAssertFalse(zh.writable)
        let en = permSummary(Permission(), .en)
        XCTAssertEqual(en.tag, "Read-only")
        XCTAssertFalse(en.writable)
    }

    func testPermSummaryWritable() {
        var p = Permission(); p.add = true
        let zh = permSummary(p, .zh)
        XCTAssertEqual(zh.tag, "可读写")
        XCTAssertTrue(zh.writable)
        XCTAssertTrue(zh.chips.contains("可上传"))
        let en = permSummary(p, .en)
        XCTAssertEqual(en.tag, "Read-write")
        XCTAssertTrue(en.writable)
        XCTAssertTrue(en.chips.contains("Can upload"))
    }

    // MARK: i18nJSON 健全性

    func testI18nJSONContainsKeysPerLanguage() {
        let zh = LStr.i18nJSON(.zh)
        XCTAssertTrue(zh.contains("\"viewersN\""))
        XCTAssertTrue(zh.contains("人正在浏览"))
        let en = LStr.i18nJSON(.en)
        XCTAssertTrue(en.contains("\"viewersN\""))
        XCTAssertTrue(en.contains("viewing"))
    }
}
