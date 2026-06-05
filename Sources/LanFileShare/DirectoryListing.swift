import Foundation

// 浏览器端目录页（与原生 app 同源的「暖纸张 × 信号广播」语言）：
// 刊头 + 面包屑 + 账本式列表（目录在前、文件夹›导航 / 文件↓下载、套准角标）+ READ ONLY 版权条。
// 只用系统字体栈，零外部依赖、局域网离线可渲染。所有 href 用绝对路径（请求路径 + 逐段编码条目名），不依赖 trailing slash。
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
            rows += row(href: encodePath(parentPath(of: requestPath)),
                        icon: "⬑", name: "返回上一级", size: nil, dir: true, up: true)
        }
        for url in sorted {
            let name = url.lastPathComponent
            let dir = isDirectory(url)
            let href = encodePath(base + name + (dir ? "/" : ""))
            let size = dir ? nil : (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
            rows += row(href: href, icon: dir ? "📁" : fileIcon(name), name: name, size: size, dir: dir)
        }

        let title = requestPath == "/" ? rootName : ((requestPath as NSString).lastPathComponent)
        let crumbs = breadcrumb(requestPath: requestPath, rootName: rootName)
        return page(title: title, crumbs: crumbs, rows: rows, isEmpty: sorted.isEmpty, count: sorted.count)
    }

    // MARK: - 片段

    private static func row(href: String, icon: String, name: String, size: Int?, dir: Bool, up: Bool = false) -> String {
        let sizeText = size.map { formatSize($0) } ?? ""
        let ch = up ? "" : (dir ? "›" : "↓")          // 目录导航 / 文件下载，暗示行为
        let liClass = up ? " class=\"up\"" : ""
        return """
        <li\(liClass)><a class="row" href="\(htmlAttr(href))">\
        <span class="ic">\(icon)</span>\
        <span class="nm">\(htmlText(name))</span>\
        <span class="sz">\(sizeText)</span>\
        <span class="ch">\(ch)</span></a></li>
        """
    }

    // 面包屑：根(站名) / seg / seg …，末段为当前不可点。
    private static func breadcrumb(requestPath: String, rootName: String) -> String {
        let segs = requestPath.split(separator: "/").map(String.init)
        var html = segs.isEmpty
            ? "<span class=\"cur\">\(htmlText(rootName))</span>"
            : "<a href=\"/\">\(htmlText(rootName))</a>"
        var cum = "/"
        for (i, seg) in segs.enumerated() {
            cum += seg + "/"
            html += "<span class=\"sep\">/</span>"
            if i == segs.count - 1 {
                html += "<span class=\"cur\">\(htmlText(seg))</span>"
            } else {
                html += "<a href=\"\(htmlAttr(encodePath(cum)))\">\(htmlText(seg))</a>"
            }
        }
        return html
    }

    private static func page(title: String, crumbs: String, rows: String, isEmpty: Bool, count: Int) -> String {
        let ledger = isEmpty
            ? #"<div class="empty"><span class="big">◍</span>这个文件夹是空的</div>"#
            : """
              <ul>\(rows)</ul>\
              <span class="mark tl"></span><span class="mark tr"></span>\
              <span class="mark bl"></span><span class="mark br"></span>
              """
        return """
        <!doctype html><html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(htmlText(title))</title>
        <style>
          :root{
            --paper:#efe9dd;--paper2:#e6decb;--surface:#fbf8f1;
            --ink:#1f1b16;--soft:#6f665a;--signal:#d23c17;--line:rgba(31,27,22,.12);
            --serif:ui-serif,"Songti SC","Noto Serif CJK SC",Georgia,"Times New Roman",serif;
            --mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;
            --sans:-apple-system,BlinkMacSystemFont,"PingFang SC",system-ui,sans-serif;
            color-scheme:light;
          }
          *{box-sizing:border-box}
          html,body{margin:0}
          body{
            font:16px/1.5 var(--sans);color:var(--ink);min-height:100vh;
            background:
              radial-gradient(120% 70% at 50% -8%,var(--surface),transparent 60%),
              radial-gradient(140% 120% at 50% 118%,var(--paper2),transparent 55%),
              var(--paper);
            background-attachment:fixed;
            padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
            -webkit-text-size-adjust:100%;
          }
          body::before{content:"";position:fixed;inset:0;pointer-events:none;opacity:.6;
            background-image:radial-gradient(rgba(31,27,22,.05) .5px,transparent .6px);
            background-size:13px 13px}
          main{max-width:680px;margin:0 auto;padding:30px 18px 36px}
          .kicker{display:flex;align-items:center;gap:8px;font:600 10px/1 var(--mono);
            letter-spacing:.22em;text-transform:uppercase;color:var(--signal)}
          .kicker .dot{width:6px;height:6px;border-radius:50%;background:var(--signal);
            animation:pulse 2s infinite}
          @keyframes pulse{0%{box-shadow:0 0 0 0 rgba(210,60,23,.45)}
            70%{box-shadow:0 0 0 9px rgba(210,60,23,0)}100%{box-shadow:0 0 0 0 rgba(210,60,23,0)}}
          h1{margin:11px 0 0;font:600 27px/1.2 var(--serif);letter-spacing:.01em;word-break:break-word}
          .crumbs{margin-top:9px;font:12px/1.6 var(--mono);color:var(--soft);word-break:break-all}
          .crumbs a{color:var(--soft);text-decoration:none;border-bottom:1px solid transparent}
          .crumbs a:hover{color:var(--signal);border-bottom-color:var(--signal)}
          .crumbs .sep{opacity:.4;margin:0 6px}
          .crumbs .cur{color:var(--ink)}

          .ledger{position:relative;margin-top:24px}
          ul{list-style:none;margin:0;padding:0;background:var(--surface);
            border:1px solid var(--line);border-radius:16px;overflow:hidden;
            box-shadow:0 22px 48px -30px rgba(31,27,22,.55);
            animation:rise .5s ease both}
          @keyframes rise{from{opacity:0;transform:translateY(10px)}to{opacity:1;transform:none}}
          li+li{border-top:1px solid var(--line)}
          a.row{position:relative;display:flex;align-items:center;gap:13px;
            min-height:56px;padding:14px 16px;color:inherit;text-decoration:none;
            transition:background .15s}
          a.row::before{content:"";position:absolute;left:0;top:0;bottom:0;width:0;
            background:var(--signal);transition:width .15s}
          a.row:hover{background:rgba(210,60,23,.05)}
          a.row:hover::before{width:3px}
          a.row:active{background:rgba(210,60,23,.11)}
          .ic{flex:none;width:26px;text-align:center;font-size:20px;line-height:1}
          .nm{flex:1;min-width:0;font:15px/1.35 var(--sans);word-break:break-all}
          .sz{flex:none;font:11.5px var(--mono);color:var(--soft);white-space:nowrap}
          .ch{flex:none;width:14px;text-align:center;font-size:16px;color:var(--soft)}
          li.up a.row{background:rgba(210,60,23,.045)}
          li.up .nm{font:600 12px var(--mono);letter-spacing:.08em;text-transform:uppercase;color:var(--signal)}
          li.up .ic{color:var(--signal)}

          .empty{text-align:center;color:var(--soft);padding:66px 20px;font:15px var(--sans)}
          .empty .big{display:block;margin-bottom:14px;font-size:46px;color:var(--signal);opacity:.8}

          .mark{position:absolute;width:10px;height:10px;pointer-events:none}
          .mark::before,.mark::after{content:"";position:absolute;background:var(--soft);opacity:.55}
          .mark::before{left:0;top:0;width:10px;height:1px}
          .mark::after{left:0;top:0;width:1px;height:10px}
          .mark.tl{top:-6px;left:-6px}
          .mark.tr{top:-6px;right:-6px}
          .mark.tr::before,.mark.tr::after{left:auto;right:0}
          .mark.bl{bottom:-6px;left:-6px}
          .mark.bl::before,.mark.bl::after{top:auto;bottom:0}
          .mark.br{bottom:-6px;right:-6px}
          .mark.br::before,.mark.br::after{top:auto;bottom:0;left:auto;right:0}

          .colophon{display:flex;justify-content:space-between;align-items:center;
            margin:16px 4px 0;font:10px/1 var(--mono);letter-spacing:.12em;
            text-transform:uppercase;color:var(--soft)}
          .colophon .ro{color:var(--signal)}
        </style></head><body>
        <main>
          <header>
            <div class="kicker"><span class="dot"></span>LAN · FILE BROADCAST</div>
            <h1>\(htmlText(title))</h1>
            <nav class="crumbs">\(crumbs)</nav>
          </header>
          <section class="ledger">\(ledger)</section>
          <footer class="colophon"><span class="ro">● 只读浏览 · READ ONLY</span><span>\(count) 项</span></footer>
        </main>
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
