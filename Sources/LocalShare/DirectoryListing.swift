import Foundation
import UniformTypeIdentifiers

// 浏览器端目录页（与原生 app 同源的票据风：暖奶油底 + 砖红强调 + 衬线标题 + 等宽技术信息）。
// 权威规范见 DESIGN.md（§5/§6.4/§9）。布局：刊头(eyebrow + 标题 + 面包屑 + 计数) → 工具栏(搜索 + 排序)
// → 类型筛选 chips(真实过滤) → 取景框列表(目录在前、类型着色方块图标、日期列) → 只读署名。
// 关键行为(纯前端 JS)：① 搜索按文件名实时过滤；② 排序 5 档(默认/名称 A→Z·Z→A/时间 新→旧·旧→新)，
// 文件夹始终分组在前；③ 类型 chips 真实过滤；④ 计数随过滤显示 N / total。无 emoji、无彩色填充图标。
// 导航：非根列表首行固定「返回上一级」（.row.back，不参与搜索/排序/过滤，空目录也保留）；
// 目录行原地进入，文件行新标签打开(target=_blank，与行尾外开箭头图标一致，列表不丢)。
// 只用系统字体栈 + 内联原生 JS，零外部依赖、局域网离线可渲染。href 用绝对路径并逐段编码。
enum DirectoryListing {
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    // 真实目录页：枚举目录 → 目录在前/名称序 → 交给渲染核心（href 基路径 = 请求路径）。
    // canUpload：单文件夹分享且开了访客上传时为 true，页面出上传按钮 + 整页拖拽，措辞联动「可读写」。
    static func html(directory: URL, requestPath: String, rootName: String, canUpload: Bool = false,
                     canReceiveText: Bool = false, lang: Lang) -> String {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey, .creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sorted = urls.sorted { a, b in
            let ad = isDirectory(a), bd = isDirectory(b)
            if ad != bd { return ad } // 目录排在文件前
            return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
        }

        let base = requestPath.hasSuffix("/") ? requestPath : requestPath + "/"
        let entries = sorted.map { (name: $0.lastPathComponent, url: $0, isDir: isDirectory($0)) }
        return render(entries: entries, base: base, requestPath: requestPath, rootName: rootName,
                      canUpload: canUpload, canReceiveText: canReceiveText, textPreview: nil, lang: lang)
    }

    // 多选虚拟根页：选中项无共同磁盘根，直接给定 (显示名=key, 真实 url, 是否目录) 列表渲染。
    // href 基路径为根 `/`，请求路径为 `/`（面包屑只显根名）；同样目录在前/名称序。
    // textPreview 非 nil：在文件项之上钉一个指向 /ls/text 的「文本」行（首行预览）——文本与文件共存、
    // 或纯文本分享（items 为空）时由 FileServer 传入；它不参与搜索/排序/筛选（同「返回上一级」行）。
    static func html(items: [(name: String, url: URL, isDir: Bool)], rootName: String,
                     textPreview: String? = nil, canReceiveText: Bool = false, lang: Lang) -> String {
        let sorted = items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return render(entries: sorted, base: "/", requestPath: "/", rootName: rootName,
                      canUpload: false, canReceiveText: canReceiveText, textPreview: textPreview, lang: lang)
    }

    // 渲染核心：给定条目(显示名 + 真实 url + 是否目录) + href 基路径 + 请求路径 + 根名，产出整页。
    // 类型/扩展名按「真实文件名」判定（url.lastPathComponent），与显示名 key 解耦。
    private static func render(entries: [(name: String, url: URL, isDir: Bool)],
                               base: String, requestPath: String, rootName: String, canUpload: Bool,
                               canReceiveText: Bool, textPreview: String?, lang: Lang) -> String {
        let fm = FileManager.default
        var rows = ""
        var folderCount = 0
        var counts: [FileCategory: Int] = [:]
        for (idx, e) in entries.enumerated() {
            let dir = e.isDir
            let vals = try? e.url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey])
            let cat = FileType.category(isDir: dir, contentType: vals?.contentType, name: e.url.lastPathComponent)
            if dir { folderCount += 1 } else { counts[cat, default: 0] += 1 }
            let href = encodePath(base + e.name + (dir ? "/" : ""))
            let date = vals?.creationDate ?? vals?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
            let meta: String
            if dir {
                let n = (try? fm.contentsOfDirectory(at: e.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).count) ?? 0
                meta = LStr.itemCount(n, lang)
            } else {
                let size = vals?.fileSize ?? 0
                meta = "\(cat.displayName(lang)) · \(formatSize(size))"
            }
            rows += row(href: href, name: e.name, meta: meta, dir: dir, cat: cat, date: date, idx: idx)
        }

        let total = entries.count
        let title = requestPath == "/" ? rootName : ((requestPath as NSString).lastPathComponent)
        let crumbs = breadcrumb(requestPath: requestPath, rootName: rootName)
        let chips = filterChips(folderCount: folderCount, counts: counts, total: total, lang: lang)
        return page(title: title, crumbs: crumbs, chips: chips, rows: rows,
                    isEmpty: entries.isEmpty, total: total, canUpload: canUpload,
                    canReceiveText: canReceiveText, backHref: parentHref(of: requestPath),
                    textPreview: textPreview, lang: lang)
    }

    // MARK: - 片段

    private static func row(href: String, name: String, meta: String, dir: Bool, cat: FileCategory, date: Date, idx: Int) -> String {
        let dateStr = dateFmt.string(from: date)
        let dateShort = String(dateStr.dropFirst(5)) // MM-DD
        let ts = Int(date.timeIntervalSince1970)
        let type = dir ? "__dir" : cat.rawValue
        let kind = dir ? "folder" : "file"
        let icClass = dir ? "ic-folder" : "ic-\(cat.rawValue)"
        let icInner = dir
            ? #"<svg viewBox="0 0 20 20" fill="none"><path d="M2 5.5A1.5 1.5 0 0 1 3.5 4h3.4a1.5 1.5 0 0 1 1.06.44l1 1A1.5 1.5 0 0 0 13 5.94h3.5A1.5 1.5 0 0 1 18 7.4v7.1A1.5 1.5 0 0 1 16.5 16h-13A1.5 1.5 0 0 1 2 14.5z" fill="currentColor"/></svg>"#
            : htmlText(extOf(name))
        let chev = dir
            ? #"<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3l5 5-5 5"/></svg>"#
            : #"<svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M5 3h-2.5v9.5h9.5V10"/><path d="M8.5 2.5H13V7"/><path d="M13 2.5L7 8.5"/></svg>"#
        // 文件行新标签打开（与外开箭头图标语义一致，浏览/下载不丢列表页）；目录行原地进入。
        let target = dir ? "" : " target=\"_blank\" rel=\"noopener\""
        return """
        <li class="row" data-kind="\(kind)" data-type="\(type)" data-name="\(htmlAttr(name.lowercased()))" data-ts="\(ts)" data-idx="\(idx)">\
        <a href="\(htmlAttr(href))"\(target)>\
        <span class="ic \(icClass)">\(icInner)</span>\
        <span class="meta"><span class="nm">\(htmlText(name))</span>\
        <span class="sub2">\(htmlText(meta))<span class="d-in"> · \(dateShort)</span></span></span>\
        <span class="d-col">\(dateStr)</span>\
        \(chev)</a></li>
        """
    }

    // 类型筛选 chips：全部 + 目录(若有) + 当前出现的文件类别。少于两组时不显示（无须筛选）。
    private static func filterChips(folderCount: Int, counts: [FileCategory: Int], total: Int, lang: Lang) -> String {
        let presentFile = FileType.order.filter { $0 != .dir && (counts[$0] ?? 0) > 0 }
        let groups = (folderCount > 0 ? 1 : 0) + presentFile.count
        guard groups >= 2 else { return "" }
        var s = "<button class=\"chip on\" data-type=\"__all\">\(L.webFilterAll(lang)) <i>\(total)</i></button>"
        if folderCount > 0 {
            s += "<button class=\"chip\" data-type=\"__dir\">\(L.webFilterDir(lang)) <i>\(folderCount)</i></button>"
        }
        for cat in presentFile {
            s += "<button class=\"chip\" data-type=\"\(cat.rawValue)\">\(cat.displayName(lang)) <i>\(counts[cat] ?? 0)</i></button>"
        }
        return "<div class=\"chips\">\(s)</div>"
    }

    // 上一级 href：根列表无上一级返回 nil；"/归档/sub/" → "/归档/"，"/归档/" → "/"。逐段编码同 encodePath。
    private static func parentHref(of requestPath: String) -> String? {
        let segs = requestPath.split(separator: "/").map(String.init)
        guard !segs.isEmpty else { return nil }
        return encodePath("/" + segs.dropLast().map { $0 + "/" }.joined())
    }

    // 面包屑：根(站名) / seg / …，末段当前不可点。Markdown 预览页（FileServer.contentResponse）复用。
    static func breadcrumb(requestPath: String, rootName: String) -> String {
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

    private static func page(title: String, crumbs: String, chips: String, rows: String,
                             isEmpty: Bool, total: Int, canUpload: Bool, canReceiveText: Bool,
                             backHref: String?, textPreview: String?, lang: Lang) -> String {
        // 措辞统一经 PermSummary 派生（同 GUI）：网页端可能出现「上传」与「可收文本」两类写能力
        let ps = permSummary(Permission(add: canUpload, recvText: canReceiveText), lang)
        let uploadButton = canUpload ? """
        <button class="upbtn" id="upbtn"><svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M8 12.5v-9M4 7l4-3.5L12 7"/></svg><span class="lbl">\(L.webUpload(lang))</span></button><input type="file" id="fi" multiple hidden>
        """ : ""
        let uploadExtras = canUpload ? """
        <div class="upbar" id="upbar"><div class="upmeta"><span id="upname"></span><span id="uppct"></span></div><div class="track"><i id="upfill"></i></div></div>
        """ : ""
        let dropMask = canUpload ? """
        <div class="dropmask" id="dropmask"><div class="dropcard">\(L.webDropHere(lang))</div></div>
        """ : ""
        // 非根列表首行固定「返回上一级」：静态 first(免双描边)，JS 不将其纳入搜索/排序/过滤。
        let backRow = backHref.map { """
        <li class="row back first"><a href="\(htmlAttr($0))">\
        <span class="ic"><svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12.5 7.5L8.5 3.5l-4 4"/><path d="M16.5 16.5h-5a3 3 0 0 1-3-3v-10"/></svg></span>\
        <span class="meta"><span class="nm">\(L.webBackToParent(lang))</span></span></a></li>
        """ } ?? ""
        // 文本行（指向 /ls/text）：钉在文件项之上，不参与搜索/排序/筛选（同返回行）。名取首行预览，
        // 纯空白回退「文本」；副标识固定「文本」。虚拟根无返回行，故它常是首行（.first 免双描边）。
        let textRow: String
        if let textPreview {
            let display = textPreview.isEmpty ? L.webText(lang) : textPreview
            let firstCls = backRow.isEmpty ? " first" : ""
            textRow = """
            <li class="row txtentry\(firstCls)"><a href="/ls/text">\
            <span class="ic ic-text"><svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M5 3.5h7.5L16 7v9.5H5z"/><path d="M12 3.5V7h3.5"/><path d="M7.5 10.5h6M7.5 13h4"/></svg></span>\
            <span class="meta"><span class="nm">\(htmlText(display))</span>\
            <span class="sub2">\(L.webText(lang))</span></span>\
            <svg class="chev" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3l5 5-5 5"/></svg></a></li>
            """
        } else {
            textRow = ""
        }
        let pinned = backRow + textRow   // 固定行（返回 + 文本），始终在最前、不参与前端处理
        let emptyHint = #"<div class="empty"><span class="big">○</span>\#(L.webEmptyFolder(lang))</div>"#
        let listInner: String
        if isEmpty && textRow.isEmpty {
            // 空目录也保留返回行，访客不至于走进死胡同
            listInner = (backRow.isEmpty ? "" : "<ul class=\"list\">\(backRow)</ul>") + emptyHint
        } else if isEmpty {
            // 无文件项但有文本（纯文本分享的虚拟根回退页）：只列文本行，不显示空文件夹提示
            listInner = "<ul class=\"list\">\(pinned)</ul>"
        } else {
            listInner = #"<ul class="list">\#(pinned)\#(rows)</ul><div class="noresult" style="display:none"><div class="nr-t">\#(L.webNoMatch(lang))</div><div class="nr-s">\#(L.webNoMatchSub(lang))</div></div>"#
        }
        return """
        <!doctype html><html lang="\(lang.htmlLang)"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(htmlText(title))</title>
        <style>
        :root{
          --accent:#df4f28;--accentSoft:rgba(223,79,40,.12);
          --bg:#efeae1;--surface:#fdfbf7;--surfaceAlt:#f5f0e7;--field:#efe9de;
          --ink:#2a261d;--inkMute:#8c8475;--inkFaint:#b4ab99;
          --line:#e7dfd1;--lineStrong:#dacfbd;
          --ok:#2f9e57;--danger:#c43c1c;--warn:#b67708;
          --serif:"Source Serif 4",ui-serif,"Songti SC","Noto Serif CJK SC",Georgia,serif;
          --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,"PingFang SC",sans-serif;
          --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
          color-scheme:light dark;
        }
        @media(prefers-color-scheme:dark){:root{
          --accentSoft:rgba(223,79,40,.18);
          --bg:#1b1814;--surface:#262219;--surfaceAlt:#211e16;--field:#1d1a14;
          --ink:#f2eee5;--inkMute:#a59d8c;--inkFaint:#6d675a;
          --line:#37322a;--lineStrong:#494238;
          --danger:#ef8a6e;--warn:#e0a83a;
        }}
        *{box-sizing:border-box}
        html,body{margin:0}
        body{font:15px/1.5 var(--sans);color:var(--ink);background:var(--bg);min-height:100vh;
          padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
          -webkit-text-size-adjust:100%;touch-action:manipulation}
        main{max-width:740px;margin:0 auto;padding:36px 40px 40px}
        .kicker{display:inline-flex;align-items:center;gap:7px;margin-bottom:12px}
        .kicker .dot{width:8px;height:8px;border-radius:50%;background:var(--accent)}
        .kicker span{font:700 12px/1 var(--sans);letter-spacing:.05em;color:var(--accent)}
        h1{margin:0;font:600 44px/1 var(--serif);letter-spacing:-.02em;word-break:break-word}
        .crumbs{margin-top:9px;font:12px/1.6 var(--mono);color:var(--inkMute);word-break:break-all}
        .crumbs a{color:var(--inkMute);text-decoration:none;border-bottom:1px dotted var(--inkFaint)}
        .crumbs a:hover{color:var(--accent);border-bottom-color:var(--accent)}
        .crumbs .sep{opacity:.4;margin:0 6px}
        .crumbs .cur{color:var(--ink)}
        .countline{margin-top:6px;display:flex;align-items:center;gap:12px}
        .count{font:13px var(--mono);color:var(--inkMute)}
        .vw{display:none;align-items:center;gap:6px;font:13px var(--mono);color:var(--ok)}
        .vw.on{display:inline-flex}
        .vw i{width:6px;height:6px;border-radius:50%;background:var(--ok)}

        .toolbar{display:flex;gap:10px;margin-top:22px;align-items:center}
        .search{display:flex;align-items:center;gap:9px;flex:1;min-width:0;height:44px;padding:0 14px;
          border-radius:12px;background:var(--surface);border:1px solid var(--line);transition:border-color .15s}
        .search.filled{border-color:var(--lineStrong)}
        .search svg{flex:none;color:var(--inkMute)}
        .search input{flex:1;min-width:0;border:none;background:transparent;outline:none;font:15px var(--sans);color:var(--ink)}
        .search .clr{display:none;width:22px;height:22px;flex:none;border:none;border-radius:50%;cursor:pointer;
          background:var(--surfaceAlt);color:var(--inkMute);align-items:center;justify-content:center}
        .search.filled .clr{display:flex}
        .sortwrap{position:relative;flex:none}
        .sortbtn{display:inline-flex;align-items:center;gap:7px;height:44px;padding:0 14px;border-radius:12px;
          cursor:pointer;font:600 14px var(--sans);white-space:nowrap;border:1px solid var(--line);
          background:var(--surface);color:var(--ink);transition:all .15s}
        .sortbtn.active{background:var(--surfaceAlt)}
        .sortbtn .cv{transition:transform .2s}
        .sortbtn.open .cv{transform:rotate(180deg)}
        .menu{position:absolute;right:0;top:calc(100% + 8px);z-index:21;min-width:200px;padding:6px;border-radius:12px;
          background:var(--surface);border:1px solid var(--line);box-shadow:0 12px 34px rgba(40,30,15,.20);display:none}
        .menu.open{display:block}
        .menu button{display:flex;align-items:center;gap:8px;width:100%;height:38px;padding:0 10px;border-radius:8px;
          border:none;cursor:pointer;text-align:left;background:transparent;color:var(--ink);font:500 13.5px var(--sans)}
        .menu button:hover{background:var(--surfaceAlt)}
        .menu button.on{background:var(--accentSoft);color:var(--accent);font-weight:700}
        .menu button .ck{width:16px;flex:none;color:var(--accent);visibility:hidden}
        .menu button.on .ck{visibility:visible}
        .scrim{position:fixed;inset:0;z-index:20;display:none}
        .scrim.open{display:block}

        .upbtn{flex:none;display:inline-flex;align-items:center;gap:7px;height:44px;padding:0 16px;border-radius:12px;
          cursor:pointer;font:600 14px var(--sans);white-space:nowrap;border:1px solid var(--accent);
          background:var(--accent);color:#fff;transition:filter .15s}
        .upbtn:hover{filter:brightness(1.07)}
        .upbar{display:none;margin-top:12px;padding:10px 14px;border-radius:12px;
          background:var(--surface);border:1px solid var(--line)}
        .upbar.on{display:block}
        .upmeta{display:flex;justify-content:space-between;gap:10px;font:12px var(--mono);color:var(--inkMute)}
        .upmeta #upname{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .upbar.err .upmeta{color:var(--danger)}
        .upbar .track{margin-top:7px;height:4px;border-radius:2px;background:var(--field);overflow:hidden}
        .upbar .track i{display:block;height:100%;width:0;background:var(--accent);transition:width .15s}
        .dropmask{position:fixed;inset:0;z-index:30;display:none;align-items:center;justify-content:center;background:var(--bg)}
        .dropmask.on{display:flex}
        .dropcard{padding:28px 40px;border:2px dashed var(--accent);border-radius:18px;background:var(--accentSoft);
          font:600 15px var(--sans);color:var(--accent);pointer-events:none}

        .chips{display:flex;gap:8px;margin-top:12px;overflow-x:auto;padding-bottom:4px;
          scrollbar-width:none;-webkit-overflow-scrolling:touch}
        .chips::-webkit-scrollbar{display:none}
        .chip{flex:none;display:inline-flex;align-items:center;gap:7px;height:38px;padding:0 16px;border-radius:999px;
          cursor:pointer;font:600 14px var(--sans);border:1px solid var(--line);background:transparent;color:var(--ink);
          white-space:nowrap;transition:all .15s}
        .chip:hover{border-color:var(--lineStrong)}
        .chip.on{background:var(--accent);border-color:var(--accent);color:#fff}
        .chip i{font-style:normal;font:600 12px var(--sans);opacity:.5}
        .chip.on i{opacity:.85}

        .ledger{position:relative;margin-top:22px;padding:8px 0}
        .mark{position:absolute;width:16px;height:16px;pointer-events:none}
        .mark.tl{top:-1px;left:-1px;border-top:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-top-left-radius:6px}
        .mark.tr{top:-1px;right:-1px;border-top:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-top-right-radius:6px}
        .mark.bl{bottom:-1px;left:-1px;border-bottom:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-bottom-left-radius:6px}
        .mark.br{bottom:-1px;right:-1px;border-bottom:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-bottom-right-radius:6px}
        .list{list-style:none;margin:0;padding:0;background:var(--surface);border:1px solid var(--line);
          border-radius:14px;overflow:hidden}
        .row{border-top:1px solid var(--line)}
        .row.first{border-top:none}
        .row>a{display:flex;align-items:center;gap:16px;padding:15px 20px;color:inherit;text-decoration:none;
          position:relative;transition:background .15s}
        .row>a::before{content:"";position:absolute;left:0;top:0;bottom:0;width:0;background:var(--accent);transition:width .15s}
        .row>a:hover{background:var(--surfaceAlt)}
        .row>a:hover::before{width:3px}
        .row.back>a{padding-top:11px;padding-bottom:11px}
        .row.back .ic{width:34px;height:34px;background:transparent;border:1px dashed var(--lineStrong)}
        .row.back .ic svg{width:17px;height:17px}
        .row.back .nm{font:500 14px var(--sans);color:var(--inkMute)}
        .ic{flex:none;width:40px;height:40px;border-radius:11px;display:flex;align-items:center;justify-content:center;
          font:700 9.5px var(--mono);letter-spacing:.02em;text-transform:lowercase;
          background:var(--surfaceAlt);color:var(--inkMute);overflow:hidden}
        .ic svg{width:20px;height:20px}
        .ic-folder{background:var(--accentSoft);color:var(--accent)}
        .ic-html{background:rgba(223,79,40,.12);color:#c4451f}
        .ic-excel{background:rgba(31,138,91,.13);color:#1f8a5b}
        .ic-image{background:rgba(42,111,219,.12);color:#2a6fdb}
        .ic-pdf{background:rgba(214,69,69,.12);color:#cf4444}
        .ic-markdown{background:rgba(122,90,224,.13);color:#7a5ae0}
        .ic-doc{background:rgba(180,120,40,.13);color:#a9772a}
        .ic-slide{background:rgba(180,86,42,.13);color:#b5562a}
        .ic-text{background:var(--accentSoft);color:var(--accent)}
        @media(prefers-color-scheme:dark){
          .ic-html,.ic-excel,.ic-image,.ic-pdf,.ic-markdown,.ic-doc,.ic-slide{background:rgba(255,255,255,.06)}
        }
        .meta{flex:1;min-width:0}
        .nm{display:block;font:500 16px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
        .sub2{display:block;margin-top:2px;font:12px var(--mono);color:var(--inkMute)}
        .d-in{display:none}
        .d-col{flex:none;width:92px;text-align:right;font:12.5px var(--mono);color:var(--inkFaint)}
        .list.sort-time .d-col{color:var(--ink);font-weight:600}
        .chev{flex:none;width:18px;height:18px;color:var(--inkFaint)}

        .noresult{list-style:none;text-align:center;padding:40px 20px}
        .nr-t{font:600 15px var(--sans);color:var(--ink)}
        .nr-s{margin-top:5px;font:13px var(--sans);color:var(--inkMute)}
        .empty{text-align:center;color:var(--inkMute);padding:64px 20px;font:15px var(--sans)}
        .empty .big{display:block;margin-bottom:14px;font-size:46px;color:var(--accent);opacity:.7}

        .colophon{text-align:center;margin-top:24px;font:12px var(--sans);color:var(--inkFaint)}
        .colophon b{font:600 12px var(--serif);color:var(--inkMute)}

        @media(max-width:560px){
          main{padding:18px 18px 24px}
          h1{font-size:30px}
          .search{height:40px}.sortbtn{height:40px}
          .sortbtn .lbl{display:none}
          .upbtn{height:40px;padding:0 13px}
          .upbtn .lbl{display:none}
          .row>a{gap:12px;padding:13px 14px}
          .ic{width:34px;height:34px}.ic svg{width:17px;height:17px}
          .nm{font-size:15px}
          .d-col{display:none}
          .d-in{display:inline}
        }
        \(canReceiveText ? SendText.css : "")
        </style></head><body>
        <main>
          <div class="kicker"><span class="dot"></span><span>\(htmlText(ps.eyebrow))</span></div>
          <h1>\(htmlText(title))</h1>
          <nav class="crumbs">\(crumbs)</nav>
          <div class="countline"><span class="count" data-total="\(total)">\(LStr.itemCount(total, lang))</span><span class="vw" id="vw"><i></i><span id="vwn"></span></span></div>

          <div class="toolbar">
            <div class="search" id="search">
              <svg width="16" height="16" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="7" r="4.3"/><path d="M10.3 10.3L14 14"/></svg>
              <input type="text" id="q" placeholder="\(L.webSearchFolder(lang))" autocomplete="off" autocapitalize="off" spellcheck="false">
              <button class="clr" id="clr" title="\(L.webClear(lang))"><svg width="11" height="11" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 4l8 8M12 4l-8 8"/></svg></button>
            </div>
            <div class="sortwrap">
              <button class="sortbtn" id="sortbtn">
                <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 5h9M4.5 8h7M6 11h4"/></svg>
                <span class="lbl" id="sortlbl">\(L.webSortLabel(lang))</span>
                <svg class="cv" width="13" height="13" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M5 6l3 3 3-3"/></svg>
              </button>
              <div class="menu" id="menu">
                <button data-k="default" data-d="asc"><svg class="ck" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>\(L.webSortDefault(lang))</button>
                <button data-k="name" data-d="asc"><svg class="ck" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>\(L.webSortNameAsc(lang))</button>
                <button data-k="name" data-d="desc"><svg class="ck" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>\(L.webSortNameDesc(lang))</button>
                <button data-k="time" data-d="desc"><svg class="ck" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>\(L.webSortTimeDesc(lang))</button>
                <button data-k="time" data-d="asc"><svg class="ck" width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3.5 8.5l3 3 6-7"/></svg>\(L.webSortTimeAsc(lang))</button>
              </div>
            </div>
            \(uploadButton)
          </div>
          \(uploadExtras)
          \(chips)
          <section class="ledger">
            <span class="mark tl"></span><span class="mark tr"></span><span class="mark bl"></span><span class="mark br"></span>
            \(listInner)
          </section>
          \(canReceiveText ? SendText.card(lang: lang) : "")
          <div class="colophon">\(L.webProvidedBy(lang)) · \(htmlText(ps.tag))</div>
        </main>
        \(dropMask)
        <script>var LS_I18N=\(LStr.i18nJSON(lang));</script>
        <script>
        (function(){
          // 在线心跳：每 15s ping 一次，刷新本机活跃时间并取回在线数；
          // 自己即 1 人，独自浏览不提示，≥2 人才显示。鉴权走已种下的 cookie。
          var vw=document.getElementById('vw'),vwn=document.getElementById('vwn');
          function ping(){
            fetch('/ls/ping'+location.search,{cache:'no-store'}).then(function(r){return r.json()}).then(function(d){
              var n=d.viewers||0;
              vwn.textContent=LS_I18N.viewersN.replace('{n}',n);
              vw.classList.toggle('on',n>=2);
            }).catch(function(){});
          }
          ping();setInterval(ping,15000);

          var list=document.querySelector('.list'); if(!list)return;
          // 固定行（返回上一级 / 文本）不参与搜索/排序/过滤，始终钉在最前（render 只 appendChild 内容行，
          // 它们天然留在前面）。
          var all=[].slice.call(list.querySelectorAll('.row:not(.back):not(.txtentry)'));
          var hasBack=!!list.querySelector('.row.back')||!!list.querySelector('.row.txtentry');
          var chips=[].slice.call(document.querySelectorAll('.chip'));
          var q=document.getElementById('q'), search=document.getElementById('search'), clr=document.getElementById('clr');
          var sortbtn=document.getElementById('sortbtn'), menu=document.getElementById('menu'), sortlbl=document.getElementById('sortlbl');
          var countEl=document.querySelector('.count'), total=+countEl.getAttribute('data-total');
          var noresult=document.querySelector('.noresult');
          var active='__all', key='default', dir='asc';

          // 排序下拉的浮层 scrim（点击空白关闭）
          var scrim=document.createElement('div'); scrim.className='scrim'; document.body.appendChild(scrim);

          function matchType(r){
            if(active==='__all')return true;
            if(active==='__dir')return r.dataset.kind==='folder';
            return r.dataset.kind==='file' && r.dataset.type===active;
          }
          function sortRows(arr){
            var folders=arr.filter(function(r){return r.dataset.kind==='folder'});
            var files=arr.filter(function(r){return r.dataset.kind!=='folder'});
            var cmp = key==='name'
              ? function(a,b){return a.dataset.name.localeCompare(b.dataset.name,'zh')}
              : key==='time'
              ? function(a,b){return (+a.dataset.ts)-(+b.dataset.ts)}
              : function(a,b){return (+a.dataset.idx)-(+b.dataset.idx)};
            folders=folders.slice().sort(cmp); files=files.slice().sort(cmp);
            if(dir==='desc' && key!=='default'){folders.reverse();files.reverse();}
            return folders.concat(files);
          }
          function render(){
            var query=(q.value||'').trim().toLowerCase();
            search.classList.toggle('filled', query.length>0);
            var vis=all.filter(function(r){return matchType(r) && (!query || r.dataset.name.indexOf(query)>=0)});
            vis=sortRows(vis);
            all.forEach(function(r){r.style.display='none';r.classList.remove('first');});
            vis.forEach(function(r,i){r.style.display='';if(i===0&&!hasBack)r.classList.add('first');list.appendChild(r);});
            if(noresult)noresult.style.display=vis.length?'none':'';
            var filtering=query!==''||active!=='__all';
            countEl.textContent=filtering? LS_I18N.countFiltered.replace('{shown}',vis.length).replace('{total}',total) : LS_I18N.countItems.replace('{n}',total);
            list.classList.toggle('sort-time', key==='time');
          }

          chips.forEach(function(c){c.addEventListener('click',function(){
            active=c.getAttribute('data-type');
            chips.forEach(function(x){x.classList.toggle('on',x===c)});
            render();
          })});
          q.addEventListener('input',render);
          clr.addEventListener('click',function(){q.value='';q.focus();render();});

          function closeMenu(){menu.classList.remove('open');sortbtn.classList.remove('open');scrim.classList.remove('open');}
          sortbtn.addEventListener('click',function(e){
            e.stopPropagation();
            var open=!menu.classList.contains('open');
            menu.classList.toggle('open',open);sortbtn.classList.toggle('open',open);scrim.classList.toggle('open',open);
          });
          scrim.addEventListener('click',closeMenu);
          [].slice.call(menu.querySelectorAll('button')).forEach(function(b){
            b.addEventListener('click',function(){
              key=b.getAttribute('data-k'); dir=b.getAttribute('data-d');
              [].slice.call(menu.querySelectorAll('button')).forEach(function(x){x.classList.toggle('on',x===b)});
              sortbtn.classList.toggle('active', key!=='default');
              sortlbl.textContent = key==='default' ? LS_I18N.sort : b.textContent.trim();
              closeMenu(); render();
            });
          });
          // 默认选中「默认顺序」
          menu.querySelector('button').classList.add('on');
          render();
        })();
        (function(){
          // 访客上传：按钮选文件 + 整页拖拽，逐个 XHR 上传（有进度事件），全部完成后刷新页面。
          // 超限文件前端直接拦（与服务端 413 同一阈值）；失败的跳过继续传下一个。
          var btn=document.getElementById('upbtn'); if(!btn)return;
          var fi=document.getElementById('fi'),bar=document.getElementById('upbar'),
              fill=document.getElementById('upfill'),nm=document.getElementById('upname'),pct=document.getElementById('uppct');
          var MAX=524288000;
          var queue=[],busy=false,done=0;

          function show(msg,p,err){
            bar.classList.add('on');bar.classList.toggle('err',!!err);
            nm.textContent=msg;pct.textContent=p==null?'':p+'%';fill.style.width=(p||0)+'%';
          }
          // 文件名按字面替换：用函数式 replace，避免名字里的 $&/$1 等被当成替换模式。
          function withName(t,name){return t.replace('{name}',function(){return name})}
          function enqueue(files){
            for(var i=0;i<files.length;i++){
              if(files[i].size>MAX){show(withName(LS_I18N.upOverLimit,files[i].name),null,true);continue}
              queue.push(files[i]);
            }
            if(!busy)next();
          }
          function next(){
            var f=queue.shift();
            if(!f){
              busy=false;
              if(done>0)location.reload();
              return;
            }
            busy=true;show(f.name,0);
            var xhr=new XMLHttpRequest();
            xhr.open('POST',location.pathname+location.search);
            xhr.upload.onprogress=function(e){
              if(e.lengthComputable)show(f.name,Math.round(e.loaded*100/e.total));
            };
            xhr.onload=function(){
              if(xhr.status===200){done++}else{show(withName(LS_I18N.upFailed,f.name),null,true)}
              next();
            };
            xhr.onerror=function(){show(withName(LS_I18N.upFailed,f.name),null,true);next();};
            var fd=new FormData();fd.append('file',f,f.name);
            xhr.send(fd);
          }

          btn.addEventListener('click',function(){fi.click()});
          fi.addEventListener('change',function(){enqueue(fi.files);fi.value=''});

          var mask=document.getElementById('dropmask'),depth=0;
          function hasFiles(e){
            var t=e.dataTransfer&&e.dataTransfer.types;
            return t&&[].slice.call(t).indexOf('Files')>=0;
          }
          document.addEventListener('dragenter',function(e){if(hasFiles(e)){depth++;mask.classList.add('on')}});
          document.addEventListener('dragleave',function(){if(--depth<=0){depth=0;mask.classList.remove('on')}});
          document.addEventListener('dragover',function(e){e.preventDefault()});
          document.addEventListener('drop',function(e){
            e.preventDefault();depth=0;mask.classList.remove('on');
            if(e.dataTransfer&&e.dataTransfer.files.length)enqueue(e.dataTransfer.files);
          });
        })();
        \(canReceiveText ? SendText.boot : "")
        </script>
        </body></html>
        """
    }

    // MARK: - 工具

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private static func extOf(_ name: String) -> String {
        let e = (name as NSString).pathExtension.lowercased()
        return e.isEmpty ? "—" : e
    }

    // 逐段百分号编码（保留 / 分隔符）。
    private static func encodePath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
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
