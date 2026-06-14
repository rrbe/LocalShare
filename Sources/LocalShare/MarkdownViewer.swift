import Foundation

// Markdown 预览（PreviewPage 壳 + 客户端渲染）。关键设计：壳页响应在 md 文件自己的 URL 上，
// 正文里的相对引用（assets/ 图片、相邻 .md 链接）由浏览器按当前页地址解析，命中现有的
// 子树服务/虚拟根映射——服务端零改写、防穿越照常生效。渲染用内嵌 vendored marked
// （MarkedJS.source），页面加载后 fetch 同 URL 的 ?raw=1 取原文解析；
// 原始 HTML 块/行内标签一律转义展示（own-files 威胁面小，仍默认不执行）。
enum MarkdownViewer {
    static func html(fileName: String, crumbs: String?, canUpload: Bool) -> String {
        PreviewPage.html(
            fileName: fileName, crumbs: crumbs, canUpload: canUpload,
            body: #"<article class="card md" id="md"><p class="ld">正在加载…</p></article>"#,
            css: css, scripts: [MarkedJS.source, rendererConfig, boot])
    }

    private static let css = """
        .md{padding:30px 34px;font:15px/1.75 var(--sans);overflow-wrap:break-word}
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
        .md .blk{color:var(--inkMute);border-bottom:1px dotted var(--inkFaint)}
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
        @media(max-width:560px){
          .md{padding:20px 18px;font-size:14.5px}
        }
        """

    // marked 渲染器安全配置（独立 <script>，在 marked 之后、boot 解析之前注入）。两件事：
    // ① 原始 HTML 块/行内标签转义为可见文本——内嵌 <script>/<iframe> 不执行；
    // ② 链接/图片 href 协议**白名单**——只放行 http/https/mailto/tel（图片再加 data:image）与相对/锚点，
    //    其余一律拦掉，堵「恶意 .md 里一个 [x](javascript:…) 链接被点开即在分享页同源执行脚本」的存储型 XSS。
    //    用白名单而非黑名单：黑名单天然漏（实体编码、未来新协议）。两个关键点：
    //    (a) **先解 HTML 实体再判**——marked 默认渲染器把 href 里的实体（&#106;avascript: / javascript&colon;）
    //        原样写进属性，浏览器解析属性时才解码，「检查串 ≠ 执行串」会被旁路；故必须解码到与浏览器一致。
    //    (b) 解码后再剥掉码点 ≤32 的字符（控制符/空白，挡 java<TAB>script:），冒号须在任何 / ? # 之前才算协议。
    //    安全 URL 返回 false → 用 marked 默认渲染，不改写正常链接。
    // /* MD-RENDERER-CONFIG */ 标记供 tools/smoke-md-link-sanitize.cjs 提取，连同真实 vendored
    // marked 在 node 里跑回归断言（测的是这份真配置，不是复刻品）。
    static let rendererConfig = """
        /* MD-RENDERER-CONFIG */
        (function(){
          var escHtml=function(s){return String(s==null?'':s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')};
          var ent=function(s){s=String(s==null?'':s);
            s=s.replace(/&#[xX]([0-9a-fA-F]+);?/g,function(_,h){var n=parseInt(h,16);return (n>=0&&n<=1114111)?String.fromCodePoint(n):''});
            s=s.replace(/&#([0-9]+);?/g,function(_,d){var n=parseInt(d,10);return (n>=0&&n<=1114111)?String.fromCodePoint(n):''});
            s=s.replace(/&colon;/gi,':');
            s=s.replace(/&(tab|newline);/gi,'');
            return s};
          var clean=function(u){u=ent(u);var o='';for(var i=0;i<u.length;i++){if(u.charCodeAt(i)>32)o+=u.charAt(i)}return o.toLowerCase()};
          var scheme=function(u){var c=clean(u);var m=/^[a-z][a-z0-9+.-]*:/.exec(c);return m?c.slice(0,m[0].length-1):''};
          var LINK_OK={http:1,https:1,mailto:1,tel:1};
          var IMG_OK={http:1,https:1,data:1};
          var linkBlocked=function(u){var s=scheme(u);return s!==''&&!LINK_OK[s]};
          var imgBlocked=function(u){var s=scheme(u);return s!==''&&!IMG_OK[s]};
          marked.use({gfm:true,breaks:false,renderer:{
            html:function(t){var s=(t&&(t.text!=null?t.text:t.raw))||'';return escHtml(s)},
            link:function(t){
              if(!linkBlocked(t&&t.href))return false;
              return '<span class="blk">'+this.parser.parseInline(t.tokens||[])+'</span>';
            },
            image:function(t){
              if(!imgBlocked(t&&t.href))return false;
              return escHtml((t&&t.text)||'');
            }
          }});
        })();
        """

    private static let boot = """
        (function(){
          var box=document.getElementById('md');
          function fail(){
            box.innerHTML='<p class="ld">加载失败 · <a href="?raw=1">查看原文</a></p>';
          }
          fetch(location.pathname+'?raw=1',{cache:'no-store'}).then(function(r){
            if(!r.ok)throw 0;return r.text();
          }).then(function(src){
            box.innerHTML=marked.parse(src);
          }).catch(fail);
        })();
        """
}
