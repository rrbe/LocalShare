import Foundation

// 扩展名 → Content-Type 映射。text/html/json/svg/js 等文本类附带 charset=utf-8，
// 否则中文 html 在手机浏览器里会乱码。未知类型回退 application/octet-stream（浏览器会下载）。
enum Mime {
    private static let map: [String: String] = [
        "html": "text/html", "htm": "text/html", "css": "text/css",
        "js": "text/javascript", "mjs": "text/javascript", "json": "application/json",
        "txt": "text/plain", "csv": "text/csv", "xml": "text/xml", "md": "text/markdown",
        "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "gif": "image/gif", "webp": "image/webp", "ico": "image/x-icon", "bmp": "image/bmp",
        "pdf": "application/pdf", "zip": "application/zip", "wasm": "application/wasm",
        "mp4": "video/mp4", "mov": "video/quicktime", "webm": "video/webm",
        "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4",
        "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    ]

    static func contentType(forExtension ext: String) -> String {
        let base = map[ext.lowercased()] ?? "application/octet-stream"
        let needsCharset = base.hasPrefix("text/")
            || base == "application/json"
            || base == "image/svg+xml"
        return needsCharset ? base + "; charset=utf-8" : base
    }
}
