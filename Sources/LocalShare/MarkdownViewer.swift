import Foundation

// Markdown 预览壳页（票据风，tokens 与 DirectoryListing 同源）。关键设计：壳页响应在
// md 文件自己的 URL 上，正文里的相对引用（assets/ 图片、相邻 .md 链接）由浏览器按
// 当前页地址解析，命中现有的子树服务/虚拟根映射——服务端零改写、防穿越照常生效。
// 渲染在客户端：内嵌 vendored marked（MarkedJS.source），页面加载后 fetch 同 URL 的
// ?raw=1 取原文解析。原始 HTML 块一律转义展示（own-files 威胁面小，仍默认不执行）。
// 布局：刊头(eyebrow + 文件名 + 面包屑/查看原文) → 取景框正文卡 → 署名。15s 心跳同列表页。
enum MarkdownViewer {
    // crumbs：调用方用 DirectoryListing.breadcrumb 生成（nil = 单文件分享，无处可回不显路径）；
    // canUpload 仅用于派生页脚/刊头措辞（permSummary），预览页本身无写操作。
    static func html(fileName: String, crumbs: String?, canUpload: Bool) -> String {
        let ps = permSummary(Permission(add: canUpload))
        let subLeft = crumbs ?? ""
        return """
        <!doctype html><html lang="zh"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(esc(fileName))</title>
        <style>
        :root{
          --accent:#df4f28;--accentSoft:rgba(223,79,40,.12);
          --bg:#efeae1;--surface:#fdfbf7;--surfaceAlt:#f5f0e7;--field:#efe9de;
          --ink:#2a261d;--inkMute:#8c8475;--inkFaint:#b4ab99;
          --line:#e7dfd1;--lineStrong:#dacfbd;
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
        }}
        *{box-sizing:border-box}
        html,body{margin:0}
        body{font:15px/1.5 var(--sans);color:var(--ink);background:var(--bg);min-height:100vh;
          padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
          -webkit-text-size-adjust:100%}
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

        .ledger{position:relative;margin-top:22px;padding:8px 0}
        .mark{position:absolute;width:16px;height:16px;pointer-events:none}
        .mark.tl{top:-1px;left:-1px;border-top:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-top-left-radius:6px}
        .mark.tr{top:-1px;right:-1px;border-top:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-top-right-radius:6px}
        .mark.bl{bottom:-1px;left:-1px;border-bottom:2px solid var(--lineStrong);border-left:2px solid var(--lineStrong);border-bottom-left-radius:6px}
        .mark.br{bottom:-1px;right:-1px;border-bottom:2px solid var(--lineStrong);border-right:2px solid var(--lineStrong);border-bottom-right-radius:6px}

        .md{background:var(--surface);border:1px solid var(--line);border-radius:14px;
          padding:30px 34px;font:15px/1.75 var(--sans);overflow-wrap:break-word}
        .md>:first-child{margin-top:0}
        .md>:last-child{margin-bottom:0}
        .md h1,.md h2,.md h3,.md h4,.md h5,.md h6{font-family:var(--serif);line-height:1.25;
          letter-spacing:-.01em;margin:1.5em 0 .55em;font-weight:600}
        .md h1{font-size:27px}
        .md h2{font-size:21px;padding-bottom:.3em;border-bottom:1px solid var(--line)}
        .md h3{font-size:17.5px}
        .md h4,.md h5,.md h6{font-size:15.5px}
        .md p{margin:.9em 0}
        .md a{color:var(--accent);text-decoration:none;border-bottom:1px dotted var(--accent)}
        .md img{max-width:100%;border-radius:10px;border:1px solid var(--line)}
        .md code{font:.92em var(--mono);background:var(--surfaceAlt);border:1px solid var(--line);
          border-radius:5px;padding:.1em .38em}
        .md pre{background:var(--surfaceAlt);border:1px solid var(--line);border-radius:10px;
          padding:14px 16px;overflow-x:auto}
        .md pre code{background:none;border:none;padding:0;font:12.5px/1.65 var(--mono)}
        .md blockquote{margin:1em 0;padding:3px 16px;border-left:3px solid var(--accent);
          color:var(--inkMute);background:var(--surfaceAlt);border-radius:0 8px 8px 0}
        .md ul,.md ol{padding-left:1.5em}
        .md li{margin:.3em 0}
        .md hr{border:none;border-top:1px dashed var(--lineStrong);margin:1.8em 0}
        .md table{border-collapse:collapse;display:block;max-width:100%;overflow-x:auto;margin:1em 0}
        .md th,.md td{border:1px solid var(--line);padding:7px 12px;font-size:13.5px}
        .md th{background:var(--surfaceAlt);font-weight:600}
        .md input[type=checkbox]{accent-color:var(--accent)}
        .ld{font:13px var(--mono);color:var(--inkMute)}
        .ld a{color:var(--accent)}

        .colophon{text-align:center;margin-top:24px;font:12px var(--sans);color:var(--inkFaint)}
        .colophon b{font:600 12px var(--serif);color:var(--inkMute)}

        @media(max-width:560px){
          main{padding:18px 18px 24px}
          h1.t{font-size:25px}
          .md{padding:20px 18px;font-size:14.5px}
        }
        </style></head><body>
        <main>
          <div class="kicker"><span class="dot"></span><span>\(esc(ps.eyebrow))</span></div>
          <h1 class="t">\(esc(fileName))</h1>
          <div class="subline">
            <nav class="crumbs">\(subLeft)</nav>
            <a class="rawlink" href="?raw=1">查看原文</a>
          </div>
          <section class="ledger">
            <span class="mark tl"></span><span class="mark tr"></span><span class="mark bl"></span><span class="mark br"></span>
            <article class="md" id="md"><p class="ld">正在加载…</p></article>
          </section>
          <div class="colophon">由 <b>LocalShare</b> 提供 · \(esc(ps.tag))</div>
        </main>
        <script>\(MarkedJS.source)</script>
        <script>
        (function(){
          // 与列表页同款在线心跳（仅保活，不显示人数）。鉴权走已种下的 cookie / 首次进入的 ?t=。
          function ping(){fetch('/ls/ping',{cache:'no-store'}).catch(function(){})}
          ping();setInterval(ping,15000);

          var box=document.getElementById('md');
          var escHtml=function(s){return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')};
          // 原始 HTML 块/行内标签转义为可见文本：md 渲染特性全保留，内嵌 <script>/<iframe> 不执行。
          marked.use({gfm:true,breaks:false,renderer:{
            html:function(t){var s=(t&&(t.text!=null?t.text:t.raw))||'';return escHtml(s)}
          }});
          function fail(){
            box.innerHTML='<p class="ld">加载失败 · <a href="?raw=1">查看原文</a></p>';
          }
          fetch(location.pathname+'?raw=1',{cache:'no-store'}).then(function(r){
            if(!r.ok)throw 0;return r.text();
          }).then(function(src){
            box.innerHTML=marked.parse(src);
          }).catch(fail);
        })();
        </script>
        </body></html>
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
