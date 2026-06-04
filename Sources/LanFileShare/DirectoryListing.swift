import Foundation

// 生成移动端友好的目录列表页：响应式 viewport、简洁卡片样式、目录在前、隐藏文件不列。
// 所有 href 都用绝对路径（当前请求路径 + 百分号编码的条目名），不依赖 trailing slash，免去重定向。
enum DirectoryListing {
    static func html(directory: URL, requestPath: String, rootName: String) -> String {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = entries.sorted { a, b in
            let ad = isDirectory(a), bd = isDirectory(b)
            if ad != bd { return ad } // 目录排在文件前
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        // requestPath 已解码（含原始中文/空格），href 需整条逐段重新编码，浏览器点击才正确。
        let base = requestPath.hasSuffix("/") ? requestPath : requestPath + "/"
        var rows = ""
        if requestPath != "/" {
            rows += row(href: encodePath(parentPath(of: requestPath)), icon: "⬑", name: "返回上一级", size: nil)
        }
        for url in sorted {
            let name = url.lastPathComponent
            let dir = isDirectory(url)
            let href = encodePath(base + name + (dir ? "/" : ""))
            let size = dir ? nil : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            rows += row(href: href, icon: dir ? "📁" : fileIcon(name), name: name, size: size)
        }

        let title = requestPath == "/" ? rootName : ((requestPath as NSString).lastPathComponent)
        return page(title: title, rows: rows, isEmpty: sorted.isEmpty)
    }

    // MARK: - 片段

    private static func row(href: String, icon: String, name: String, size: Int?) -> String {
        let sizeText = size.map { " · " + formatSize($0) } ?? ""
        return """
        <li><a href="\(htmlAttr(href))"><span class="i">\(icon)</span>\
        <span class="n">\(htmlText(name))</span><span class="s">\(sizeText)</span></a></li>
        """
    }

    private static func page(title: String, rows: String, isEmpty: Bool) -> String {
        let body = isEmpty
            ? #"<p class="empty">这个文件夹是空的。</p>"#
            : "<ul>\(rows)</ul>"
        return """
        <!doctype html><html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(htmlText(title))</title>
        <style>
          :root{color-scheme:light dark}
          *{box-sizing:border-box}
          body{margin:0;font:16px/1.5 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
               background:#f2f2f7;color:#111;padding:env(safe-area-inset-top) 0 0}
          @media(prefers-color-scheme:dark){body{background:#000;color:#eee}}
          header{padding:18px 20px 10px;font-weight:600;font-size:18px;
                 word-break:break-all}
          ul{list-style:none;margin:0 12px 24px;padding:0;border-radius:14px;overflow:hidden;
             background:#fff}
          @media(prefers-color-scheme:dark){ul{background:#1c1c1e}}
          li+li{border-top:1px solid #ececec}
          @media(prefers-color-scheme:dark){li+li{border-top:1px solid #2c2c2e}}
          a{display:flex;align-items:center;gap:12px;padding:14px 16px;text-decoration:none;
            color:inherit}
          a:active{background:#0001}
          .i{font-size:20px;flex:none;width:24px;text-align:center}
          .n{flex:1;min-width:0;word-break:break-all}
          .s{flex:none;color:#8a8a8e;font-size:13px}
          .empty{text-align:center;color:#8a8a8e;padding:60px 20px}
        </style></head><body>
        <header>📂 \(htmlText(title))</header>
        \(body)
        </body></html>
        """
    }

    // MARK: - 工具

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    // 逐段百分号编码（保留 / 分隔符），空格/中文等转义，浏览器导航才不出错。
    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
    }

    private static func parentPath(of path: String) -> String {
        var p = path
        if p.hasSuffix("/") { p.removeLast() }
        if let idx = p.lastIndex(of: "/") {
            let parent = String(p[...idx])
            return parent.isEmpty ? "/" : parent
        }
        return "/"
    }

    private static func fileIcon(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "html", "htm": return "🌐"
        case "pdf": return "📕"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp": return "🖼️"
        case "mp4", "mov", "webm": return "🎬"
        case "mp3", "wav", "m4a": return "🎵"
        case "zip": return "🗜️"
        default: return "📄"
        }
    }

    private static func formatSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static func htmlText(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func htmlAttr(_ s: String) -> String {
        htmlText(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
