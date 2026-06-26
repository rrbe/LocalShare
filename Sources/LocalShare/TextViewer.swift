import Foundation

// 文本预览页（Mac→手机发文本，PreviewPage 壳 + 客户端渲染）。与 md/json/csv 查看器同套路，
// 但内容源不是磁盘文件而是内存里的一段字符串：服务端把文本以安全的 JS 字符串内联进页面
// （共用 LStr.jsEscape：转义 < 挡 </script>、转义换行/行分隔符破坏 JS 串），客户端只读地放进 <pre>。
// 关键约束（见 PLAN.md「传递文本」与 CLAUDE.md）：
//  · 纯文本展示——不当 Markdown 渲染（任意文本里的 * _ # 不该被吃掉），用 textContent 注入天然防 XSS；
//  · 复制按钮必须走 execCommand 回退——纯 http 局域网是非安全上下文，navigator.clipboard 不可用；
//  · 自动链接只认 http(s)，由正则保证 scheme，不会引入 javascript: 之类。
enum TextViewer {
    // text：要展示/复制的原文；crumbs：与文件共存于虚拟根时显示「分享内容 / 文本」，纯文本分享传 nil。
    static func html(text: String, crumbs: String?, canUpload: Bool, canReceiveText: Bool = false, lang: Lang) -> String {
        PreviewPage.html(
            fileName: L.webText(lang), crumbs: crumbs, canUpload: canUpload, lang: lang,
            body: """
            <article class="card txt">
              <pre id="txtbody" class="txtbody"></pre>
              <div class="txtbar">
                <span class="hint">\(PreviewPage.esc(L.webTextHint(lang)))</span>
                <button class="copybtn" id="copybtn">\
            <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M3.5 10.5h-1V2.5h8v1"/></svg>\
            <span class="lbl">\(PreviewPage.esc(L.webCopy(lang)))</span></button>
              </div>
            </article>
            """,
            css: css, scripts: ["var LS_TEXT=\"\(LStr.jsEscape(text))\";", boot],
            rawLabel: L.webViewRawText(lang), canReceiveText: canReceiveText)
    }

    private static let css = """
        .txt{padding:0;overflow:hidden}
        .txtbar{display:flex;align-items:center;gap:12px;padding:12px 16px;border-top:1px solid var(--line);
          background:var(--surfaceAlt)}
        .txtbar .hint{flex:1;min-width:0;font:12px var(--mono);color:var(--inkMute);
          overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .copybtn{flex:none;display:inline-flex;align-items:center;gap:7px;height:36px;padding:0 15px;border-radius:10px;
          cursor:pointer;font:600 14px var(--sans);white-space:nowrap;border:1px solid var(--accent);
          background:var(--accent);color:#fff;transition:filter .15s,background .15s,border-color .15s}
        .copybtn:hover{filter:brightness(1.07)}
        .copybtn.done{background:var(--ok);border-color:var(--ok)}
        .txtbody{margin:0;padding:22px 24px;font:13.5px/1.7 var(--mono);color:var(--ink);
          white-space:pre-wrap;word-break:break-word;overflow-wrap:anywhere}
        .txtbody a{color:var(--accent);text-decoration:none;border-bottom:1px dotted var(--accent)}
        @media(max-width:560px){
          .txtbody{padding:16px 16px;font-size:13px}
          .txtbar .hint{display:none}
          .copybtn{flex:1}
        }
        """

    // 启动脚本：把 LS_TEXT 放进 <pre>（textContent，安全），把裸 http(s) URL 拆成可点链接，接好复制按钮。
    private static let boot = """
        (function(){
          var pre=document.getElementById('txtbody');
          // 自动链接：只识别 http(s)，scheme 由正则保证，a.href 不会落入 javascript: 等。
          var re=/https?:\\/\\/[^\\s<>"'`]+/g, t=LS_TEXT, last=0, m;
          while((m=re.exec(t))){
            if(m.index>last)pre.appendChild(document.createTextNode(t.slice(last,m.index)));
            var a=document.createElement('a');
            a.href=m[0];a.textContent=m[0];a.target='_blank';a.rel='noopener noreferrer';
            pre.appendChild(a);
            last=re.lastIndex;
          }
          if(last<t.length)pre.appendChild(document.createTextNode(t.slice(last)));

          var btn=document.getElementById('copybtn'),lbl=btn.querySelector('.lbl'),timer;
          var orig=lbl.textContent;   // 「复制」初始文案由服务端 L.webCopy 渲染，捕获后复原——单一来源，不在 i18n 里重复
          function flash(){
            lbl.textContent=LS_I18N.copied;btn.classList.add('done');
            clearTimeout(timer);timer=setTimeout(function(){lbl.textContent=orig;btn.classList.remove('done');},1600);
          }
          function legacy(){
            // 纯 http 局域网（非安全上下文）下 navigator.clipboard 不可用，回退选中 + execCommand。
            // readonly + 移到屏外：iOS 不弹软键盘、不缩放、不顶起视口（修复点复制时页面跳动）。
            var ta=document.createElement('textarea');ta.value=LS_TEXT;ta.readOnly=true;
            ta.style.cssText='position:fixed;top:0;left:-9999px;font-size:16px';
            document.body.appendChild(ta);
            ta.focus();ta.setSelectionRange(0,ta.value.length);
            try{document.execCommand('copy');flash();}catch(e){}
            document.body.removeChild(ta);
          }
          btn.addEventListener('click',function(){
            if(navigator.clipboard&&navigator.clipboard.writeText){
              navigator.clipboard.writeText(LS_TEXT).then(flash,legacy);
            }else{legacy();}
          });
        })();
        """
}
