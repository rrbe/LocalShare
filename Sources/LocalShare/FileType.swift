import Foundation
import UniformTypeIdentifiers

// 文件类型分类，集中维护一份。供浏览器目录页（筛选条/图标）与原生 UI（分享卡类型印章）共用。
//
// 识别策略：以系统 UTType（UniformTypeIdentifiers，权威类型库 + 类型继承）为主——不只看后缀，
// 而是用系统解析出的 contentType + conforms(to:) 判定媒体大类，覆盖长尾扩展名与 app 声明类型；
// 办公文档按扩展名稳妥归类（UTType 大类映射不理想，如 docx/xlsx 是 zip 容器，易被误判为压缩包）；
// 最后纯扩展名兜底（系统未给出类型时）。
// 注：UTType 来自系统类型库（后缀 + 元数据驱动），非逐字节嗅探；要识别「扩展名造假」的文件需另加 magic-byte 检测。
enum FileCategory: String {
    case dir, html, pdf, image, markdown, excel, doc, slide, video, audio, archive, other

    // 中文名：目录页筛选条用；原生卡片印章亦取此（dir/other 由 UI 另行就地适配为「文件夹」「文件」）。
    var displayName: String {
        switch self {
        case .dir:      return "目录"
        case .html:     return "网页"
        case .pdf:      return "PDF"
        case .image:    return "图片"
        case .markdown: return "Markdown"
        case .excel:    return "表格"
        case .doc:      return "文档"
        case .slide:    return "幻灯片"
        case .video:    return "视频"
        case .audio:    return "音频"
        case .archive:  return "压缩包"
        case .other:    return "其他"
        }
    }

    // 浏览器目录页用的 emoji 图标。
    var emoji: String {
        switch self {
        case .dir:      return "📁"
        case .html:     return "🌐"
        case .pdf:      return "📕"
        case .image:    return "🖼️"
        case .markdown: return "📝"
        case .excel:    return "📊"
        case .doc:      return "📄"
        case .slide:    return "📽️"
        case .video:    return "🎬"
        case .audio:    return "🎵"
        case .archive:  return "🗜️"
        case .other:    return "📄"
        }
    }

    // 原生 UI（分享卡印章）用的 SF Symbol。
    var sfSymbol: String {
        switch self {
        case .dir:      return "shippingbox"
        case .html:     return "globe"
        case .pdf:      return "doc.richtext"
        case .image:    return "photo"
        case .markdown: return "doc.plaintext"
        case .excel:    return "tablecells"
        case .doc:      return "doc.text"
        case .slide:    return "rectangle.on.rectangle"
        case .video:    return "film"
        case .audio:    return "music.note"
        case .archive:  return "archivebox"
        case .other:    return "doc"
        }
    }
}

enum FileType {
    // 筛选条 / 印章的显示顺序。
    static let order: [FileCategory] = [.dir, .html, .pdf, .image, .markdown, .excel, .doc, .slide, .video, .audio, .archive, .other]

    // 单个 URL：实时取系统 contentType（拿不到再退扩展名）。用于原生分享卡。
    static func category(of url: URL, isDir: Bool) -> FileCategory {
        if isDir { return .dir }
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        return classify(type, ext: url.pathExtension)
    }

    // 批量场景（目录列表）：UTType 已随 contentsOfDirectory 一并取出，避免重复 I/O。
    static func category(isDir: Bool, contentType: UTType?, name: String) -> FileCategory {
        if isDir { return .dir }
        return classify(contentType, ext: (name as NSString).pathExtension)
    }

    private static func classify(_ contentType: UTType?, ext: String) -> FileCategory {
        let e = ext.lowercased()
        // 1) 办公 / 直觉分组：UTType 大类映射不理想，按扩展名稳妥归类
        switch e {
        case "md", "markdown", "mdown":       return .markdown
        case "csv", "numbers", "xls", "xlsx": return .excel
        case "doc", "docx", "pages", "rtf":   return .doc
        case "ppt", "pptx", "key":            return .slide
        default: break
        }
        // 2) 系统 UTType（权威类型库 + 继承）识别媒体大类——不只看后缀
        if let t = contentType ?? UTType(filenameExtension: e) {
            if t.conforms(to: .pdf)   { return .pdf }
            if t.conforms(to: .html)  { return .html }
            if t.conforms(to: .image) { return .image }
            if t.conforms(to: .audio) { return .audio }                              // 音频先于视频：纯音频不属 .movie
            if t.conforms(to: .movie) || t.conforms(to: .audiovisualContent) { return .video }
            if t.conforms(to: .archive) { return .archive }
        }
        // 3) 纯扩展名兜底（系统未给出类型时）
        return byExtension(e)
    }

    private static func byExtension(_ e: String) -> FileCategory {
        switch e {
        case "html", "htm": return .html
        case "pdf": return .pdf
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "heif", "tiff", "tif", "ico", "avif": return .image
        case "md", "markdown", "mdown": return .markdown
        case "xls", "xlsx", "csv", "numbers": return .excel
        case "doc", "docx", "pages", "rtf", "txt": return .doc
        case "ppt", "pptx", "key": return .slide
        case "mp4", "mov", "webm", "mkv", "avi", "m4v": return .video
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return .audio
        case "zip", "rar", "7z", "gz", "tar", "bz2": return .archive
        default: return .other
        }
    }
}
