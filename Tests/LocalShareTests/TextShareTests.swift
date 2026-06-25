import XCTest
@testable import LocalShare

// 传递文本（v1）的纯函数单测：文本条目首行预览、文本历史记录的 Codable 往返与身份/显示名。
// 不触磁盘、不起服务。
final class TextShareTests: XCTestCase {

    // MARK: FileServer.textPreview —— 列表/历史里的文本条目显示名

    func testTextPreviewFirstLine() {
        XCTAssertEqual(FileServer.textPreview("first line\nsecond"), "first line")
    }

    func testTextPreviewTrimsWhitespace() {
        XCTAssertEqual(FileServer.textPreview("   padded   \nx"), "padded")
    }

    func testTextPreviewTruncatesTo60() {
        let long = String(repeating: "x", count: 100)
        XCTAssertEqual(FileServer.textPreview(long).count, 60)
    }

    func testTextPreviewSkipsLeadingBlankLines() {
        // 跳过开头的空行/空白行，取首个有内容的行
        XCTAssertEqual(FileServer.textPreview("   \n\nreal content"), "real content")
    }

    func testTextPreviewAllBlankIsEmpty() {
        // 整段纯空白 → 预览为空（展示层回退到「文本」）
        XCTAssertEqual(FileServer.textPreview("   \n\t\n  "), "")
    }

    func testTextPreviewHandlesCRLF() {
        XCTAssertEqual(FileServer.textPreview("line1\r\nline2"), "line1")
    }

    // MARK: RecentShare 文本条目

    func testTextRecentIdentityByContent() {
        let a = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "hello")
        let b = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "hello")
        let c = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "world")
        XCTAssertEqual(a.id, b.id)        // 同文本同身份（去重 / 重分享移到顶部）
        XCTAssertNotEqual(a.id, c.id)
        XCTAssertTrue(a.isText)
        XCTAssertTrue(a.exists)           // 文本条目恒存在，不依赖文件系统
    }

    func testTextRecentDisplayName() {
        let r = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "preview here\nmore")
        XCTAssertEqual(r.displayName(.zh), "preview here")
        // 纯空白文本 → 回退到本地化「文本 / Text」
        let blank = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "   ")
        XCTAssertEqual(blank.displayName(.zh), L.webText(.zh))
        XCTAssertEqual(blank.displayName(.en), L.webText(.en))
    }

    func testTextRecentCodableRoundTrip() throws {
        let r = RecentShare(paths: [], isFile: false, detail: "5 字", date: Date(timeIntervalSince1970: 1000), text: "café <b>")
        let data = try JSONEncoder().encode(r)
        let back = try JSONDecoder().decode(RecentShare.self, from: data)
        XCTAssertEqual(back.text, "café <b>")
        XCTAssertTrue(back.isText)
        XCTAssertEqual(back.id, r.id)
    }

    // 文件条目身份与选中顺序无关（同 isLive/isCurrentShare 的 Set(paths) 口径）：同一组文件
    // 不同顺序 → 同一 id，避免历史里出现两条等价记录、且都被判为「正在直播」。
    func testFileRecentIdOrderInsensitive() {
        let a = RecentShare(paths: ["/x/a", "/x/b"], isFile: false, detail: "", date: Date())
        let b = RecentShare(paths: ["/x/b", "/x/a"], isFile: false, detail: "", date: Date())
        XCTAssertEqual(a.id, b.id)
        // 与文本条目身份互不撞车
        let txt = RecentShare(paths: [], isFile: false, detail: "", date: Date(), text: "/x/a\n/x/b")
        XCTAssertNotEqual(a.id, txt.id)
    }

    // 旧记录（无 text 字段）解码后 text 为 nil、仍是文件条目——迁移兼容。
    func testLegacyRecentDecodesWithoutText() throws {
        let json = #"{"paths":["/a/b.txt"],"isFile":true,"detail":"1 KB","date":0}"#
        let back = try JSONDecoder().decode(RecentShare.self, from: Data(json.utf8))
        XCTAssertNil(back.text)
        XCTAssertFalse(back.isText)
        XCTAssertEqual(back.paths, ["/a/b.txt"])
    }
}
