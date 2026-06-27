import Foundation

// 一条最近分享记录（持久化到 UserDefaults）。paths 支持多选（1=单项、N=多选）；
// text 非 nil 即「文本分享」条目（paths 为空，仅在「记住分享的文本」开启时落库）。
struct RecentShare: Codable, Identifiable, Equatable {
    let paths: [String]
    let isFile: Bool       // 仅单项有意义
    let detail: String
    let date: Date
    let text: String?      // 文本分享条目的原文；文件条目为 nil

    var isText: Bool { text != nil }
    var isMultiple: Bool { paths.count > 1 }
    // 文本条目以内容作身份（同一段文本去重、重分享移到顶部）；文件条目以路径**集合**作身份
    //（排序后拼接，与 isLive / isCurrentShare 的 Set(paths) 口径一致——同一组文件不同选中顺序视作同一条，避免去重失效）。
    var id: String { text.map { "\u{1}text\u{1}\($0)" } ?? Set(paths).sorted().joined(separator: "\n") }
    // 文本给首行预览（空白回退「文本」），多选给本地化计数名，单项给文件名。由持有 lang 的 View 传入。
    func displayName(_ lang: Lang) -> String {
        if let text { let p = FileServer.textPreview(text); return p.isEmpty ? L.webText(lang) : p }
        if isMultiple { return LStr.multiItemName(paths.count, lang) }
        return paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
    }
    // 文本条目恒可重分享；文件条目只要还有一项存在即可（reshare 时再剔除缺失项）。
    var exists: Bool {
        if text != nil { return true }
        let fm = FileManager.default
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    init(paths: [String], isFile: Bool, detail: String, date: Date, text: String? = nil) {
        self.paths = paths; self.isFile = isFile; self.detail = detail; self.date = date; self.text = text
    }

    // 兼容旧记录：旧版用单 `path` 字段，迁移为 `paths = [path]`；旧记录无 text 字段，解码缺省为 nil。
    enum CodingKeys: String, CodingKey { case paths, path, isFile, detail, date, text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decode([String].self, forKey: .paths) {
            paths = arr
        } else if let p = try? c.decode(String.self, forKey: .path) {
            paths = [p]
        } else {
            paths = []
        }
        isFile = (try? c.decode(Bool.self, forKey: .isFile)) ?? false
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
        text = try? c.decodeIfPresent(String.self, forKey: .text)
    }
    // 显式 encode（CodingKeys 含迁移用的 .path，会阻断合成）：只写 paths 等当前字段。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encode(isFile, forKey: .isFile)
        try c.encode(detail, forKey: .detail)
        try c.encode(date, forKey: .date)
        try c.encodeIfPresent(text, forKey: .text)
    }
}
