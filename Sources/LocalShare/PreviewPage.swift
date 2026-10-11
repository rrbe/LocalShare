import Foundation

// 预览壳页共用骨架：Markdown / JSON / CSV 查看器共享 tokens、刊头（kicker + 文件名 + 面包屑 +
// 「查看原文」）、取景框、署名与 15s 在线心跳；各查看器只交内容卡 HTML、专属 CSS 与脚本。
// 两条铁律（详见 CLAUDE.md 与 DESIGN.md §6.5）：① 壳页必须与文件同 URL——正文相对引用与
// ?raw=1 取原文都靠它成立，绝不可挪去保留路径；② 措辞经 permSummary 派生，不硬编码「只读」。
enum PreviewPage {
    // body：内容区 HTML，自带卡片元素（用 .card 取得 surface 底 + 描边 + 圆角，如
    // `<article class="card md">…</article>`）。css：查看器专属样式。scripts：依序各成一个
    // <script>（vendored 库与启动脚本分开传，启动脚本约定从 location.pathname + '?raw=1' 取原文）。
    // rawLabel：页角「查看原文」链接文案，默认「查看原文 / View source」；纯文本预览传「查看原始文本」。
    static func html(fileName: String, crumbs: String?, canUpload: Bool, lang: Lang,
                     body: String, css: String, scripts: [String], rawLabel: String? = nil,
                     canReceiveText: Bool = false) -> String {
        let ps = permSummary(Permission(add: canUpload, recvText: canReceiveText), lang)
        // 收件箱开启时，预览/文本壳页底部嵌同一份「发文本给电脑」表单（与列表页一致）——让纯文本分享、
        // 单文件预览等没有列表页的形态也能就地回填文本给 Mac。
        let allScripts = canReceiveText ? scripts + [SendText.boot] : scripts
        let scriptTags = allScripts.map { "<script>\($0)</script>" }.joined(separator: "\n")
        return """
        <!doctype html><html lang="\(lang.htmlLang)"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(esc(fileName))</title>
        <style>
        :root{
          --accent:#df4f28;--accentSoft:rgba(223,79,40,.12);
          --bg:#efeae1;--surface:#fdfbf7;--surfaceAlt:#f5f0e7;--field:#efe9de;
          --ink:#2a261d;--inkMute:#8c8475;--inkFaint:#b4ab99;
          --line:#e7dfd1;--lineStrong:#dacfbd;
          --ok:#2f9e57;--warn:#b67708;
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
          --warn:#e0a83a;
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
        h1.t{margin:0;font:600 34px/1.15 var(--serif);letter-spacing:-.02em;word-break:break-word}
        .subline{display:flex;align-items:baseline;gap:14px;margin-top:9px}
        .crumbs{flex:1;min-width:0;font:12px/1.6 var(--mono);color:var(--inkMute);word-break:break-all}
        .crumbs a{color:var(--inkMute);text-decoration:none;border-bottom:1px dotted var(--inkFaint)}
        .crumbs a:hover{color:var(--accent);border-bottom-color:var(--accent)}
        .crumbs .sep{opacity:.4;margin:0 6px}
        .crumbs .cur{color:var(--ink)}
        .rawlink{flex:none;font:12px var(--mono);color:var(--inkMute);text-decoration:none;
          border-bottom:1px dotted var(--inkFaint)}
        .rawlink:hover{color:var(--accent);border-bottom-color:var(--accent)}
        \(WebWideLayout.css)

        .ledger{position:relative;margin-top:22px;padding:8px 0}
        .mark{position:absolute;width:16px;height:16px;pointer-events:none}
        .mark.tl{top:-1px;left:-1px;border-top:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-top-left-radius:6px}
        .mark.tr{top:-1px;right:-1px;border-top:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-top-right-radius:6px}
        .mark.bl{bottom:-1px;left:-1px;border-bottom:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-bottom-left-radius:6px}
        .mark.br{bottom:-1px;right:-1px;border-bottom:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-bottom-right-radius:6px}
        .card{background:var(--surface);border:1px solid var(--line);border-radius:14px}
        .ld{font:13px var(--mono);color:var(--inkMute)}
        .ld a{color:var(--accent)}

        .colophon{text-align:center;margin-top:24px;font:12px var(--sans);color:var(--inkFaint)}
        .colophon b{font:600 12px var(--serif);color:var(--inkMute)}

        @media(max-width:560px){
          main{padding:18px 18px 24px}
          h1.t{font-size:25px}
        }
        \(css)
        \(canReceiveText ? SendText.css : "")
        </style></head><body>
        <main>
          <div class="kicker"><span class="dot"></span><span>\(esc(ps.eyebrow))</span></div>
          <h1 class="t">\(esc(fileName))</h1>
          <div class="subline">
            <nav class="crumbs">\(crumbs ?? "")</nav>
            <a class="rawlink" href="?raw=1">\(esc(rawLabel ?? L.webViewRaw(lang)))</a>
            \(WebWideLayout.button(lang))
          </div>
          <section class="ledger">
            <span class="mark tl"></span><span class="mark tr"></span><span class="mark bl"></span><span class="mark br"></span>
            \(body)
          </section>
          \(canReceiveText ? SendText.card(lang: lang) : "")
          <div class="colophon">\(L.webProvidedBy(lang))</div>
        </main>
        <script>var LS_I18N=\(LStr.i18nJSON(lang));</script>
        <script>\(WebWideLayout.script)</script>
        <script>
        (function(){
          // 与列表页同款在线心跳（仅保活，不显示人数）。鉴权走已种下的 cookie / 首次进入的 ?t=。
          function ping(){fetch('/ls/ping',{cache:'no-store'}).catch(function(){})}
          ping();setInterval(ping,15000);
        })();
        </script>
        \(scriptTags)
        </body></html>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// 目录页与 LocalShare 自定义预览共用；浏览器原生支持的文件直接返回原文件，不会出现此按钮。
enum WebWideLayout {
    static func button(_ lang: Lang) -> String {
        """
        <button class="widebtn" id="widebtn" data-expand="\(L.expandWide(lang))" data-collapse="\(L.exitWide(lang))" title="\(L.expandWide(lang))" aria-label="\(L.expandWide(lang))">
          <svg class="expand" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M6 3H3v3M10 3h3v3M6 13H3v-3M10 13h3v-3"/></svg>
          <svg class="collapse" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h3V3M13 6h-3V3M3 10h3v3M13 10h-3v3"/></svg>
        </button>
        """
    }

    static let css = """
        body.wide main{max-width:none;padding-left:clamp(24px,4vw,64px);padding-right:clamp(24px,4vw,64px)}
        .widebtn{flex:none;display:inline-flex;align-items:center;justify-content:center;width:34px;height:34px;padding:0;
          border-radius:10px;border:1px solid var(--line);background:var(--surface);color:var(--inkMute);cursor:pointer}
        .widebtn:hover{border-color:var(--lineStrong);color:var(--ink)}
        .widebtn svg{width:16px;height:16px}
        .widebtn .collapse,body.wide .widebtn .expand{display:none}
        body.wide .widebtn .collapse{display:block}
        @media(max-width:760px){.widebtn{display:none}}
        """

    static let script = """
        (function(){
          var b=document.getElementById('widebtn'),wide=false;if(!b)return;
          try{wide=sessionStorage.getItem('ls-wide')==='1'}catch(e){}
          function apply(v){
            wide=v;document.body.classList.toggle('wide',v);
            var label=v?b.dataset.collapse:b.dataset.expand;b.title=label;b.setAttribute('aria-label',label);
            try{sessionStorage.setItem('ls-wide',v?'1':'0')}catch(e){}
          }
          apply(wide);b.addEventListener('click',function(){apply(!wide)});
        })();
        """
}
