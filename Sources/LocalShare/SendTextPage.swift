import Foundation

// 手机→Mac「发文本给电脑」表单（传递文本 v2 的手机端）。两处复用同一份片段：
//  · 列表页（DirectoryListing）：收件箱开启时挂在文件列表之下，与访客上传表单同条件出现；
//  · 独立发送页（/ls/send）：「只收文本、没分享任何内容」时二维码直指此页（FileServer 在 textInboxEnabled 时服务）。
// 关键约束（见 PLAN.md「传递文本 · v2」与 CLAUDE.md）：
//  · 纯 http 局域网是非安全上下文——这里走 fetch POST 原文，无须 clipboard，不受该限制影响；
//  · 单条上限与服务端 textInboxLimit（64KB）对齐，前端按 UTF-8 字节数先行拦截（Blob().size）；
//  · 投递的文本只在 Mac 端 SwiftUI Text 里显示（天然不执行），故无回显 XSS 之虞。
enum SendText {
    // 表单卡片片段（不含页面外壳）。withHead：列表页里需要标题区分于文件列表，独立发送页靠页面 H1 故省略。
    static func card(lang: Lang, withHead: Bool = true) -> String {
        let head = withHead ? """
        <div class="sendhead">\
        <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.5l11.5-5-4 11-2.5-4.5z"/><path d="M7 10l2.5-2.5"/></svg>\
        <span>\(esc(L.webSendHead(lang)))</span></div>
        """ : ""
        return """
        <section class="sendbox card">
          \(head)
          <textarea id="sendta" class="sendta" placeholder="\(esc(L.webSendPlaceholder(lang)))" autocomplete="off"></textarea>
          <div class="sendbar">
            <span class="sendstatus" id="sendstatus"></span>
            <button class="sendbtn" id="sendbtn">\
        <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M2 8.5l11.5-5-4 11-2.5-4.5z"/></svg>\
        <span>\(esc(L.webSendButton(lang)))</span></button>
          </div>
          <div class="senthist" id="senthist"></div>
        </section>
        """
    }

    static let css = """
        .sendbox{margin-top:22px;padding:0;overflow:hidden}
        .sendhead{display:flex;align-items:center;gap:8px;padding:13px 16px;border-bottom:1px solid var(--line);
          background:var(--surfaceAlt);font:600 13px var(--sans);color:var(--ink)}
        .sendhead svg{color:var(--accent)}
        .sendta{display:block;width:100%;min-height:120px;resize:vertical;border:none;outline:none;
          background:transparent;color:var(--ink);font:13.5px/1.6 var(--mono);padding:16px 18px;
          -webkit-text-size-adjust:100%}
        .sendta::placeholder{color:var(--inkFaint)}
        .sendbar{display:flex;align-items:center;gap:12px;padding:10px 14px;border-top:1px solid var(--line);
          background:var(--surfaceAlt)}
        .sendstatus{flex:1;min-width:0;font:12px var(--mono);color:var(--inkMute);
          overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
        .sendstatus.ok{color:var(--ok)}
        .sendstatus.err{color:var(--danger)}
        .sendbtn{flex:none;display:inline-flex;align-items:center;gap:7px;height:38px;padding:0 18px;border-radius:10px;
          cursor:pointer;font:600 14px var(--sans);white-space:nowrap;border:1px solid var(--accent);
          background:var(--accent);color:#fff;transition:filter .15s}
        .sendbtn:hover{filter:brightness(1.07)}
        .sendbtn:disabled{opacity:.5;cursor:default}
        /* 已发送历史：浏览器本地留存（localStorage），点一条回填到输入框便于改发/重发。右侧缀紧凑相对时间。 */
        .senthist:empty{display:none}
        .senthist{border-top:1px solid var(--line)}
        .sh-title{padding:10px 16px 4px;font:600 11px var(--sans);letter-spacing:.04em;color:var(--inkMute)}
        .sh-item{display:flex;align-items:flex-start;gap:10px;padding:8px 16px;cursor:pointer;
          border-top:1px solid var(--line);font:12px/1.5 var(--mono);color:var(--ink)}
        .sh-item:first-of-type{border-top:none}
        .sh-item:active{background:var(--surfaceAlt)}
        .sh-text{flex:1;min-width:0;white-space:pre-wrap;word-break:break-word;
          display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
        .sh-time{flex:none;color:var(--inkFaint);font-size:11px;white-space:nowrap;padding-top:1px}
        /* 手机上输入框字号 <16px 时 iOS 聚焦会自动放大页面，置 16px 杜绝。 */
        @media(max-width:560px){.sendta{font-size:16px}}
        """

    // 启动脚本：发送 textarea 内容到 POST /ls/text。鉴权走已种下的 cookie（同源）。超 64KB 前端先拦。
    // 成功清空输入并闪「已发送」+ 记进本地「已发送」历史（localStorage，点一条回填）。失败按服务端 JSON
    // {"error":…} 或状态码给出具体原因（403=链接已失效需重扫、413=超限、网络错误）。Cmd/Ctrl+Enter 快捷发送。
    static let boot = """
        (function(){
          var ta=document.getElementById('sendta'),btn=document.getElementById('sendbtn'),
              st=document.getElementById('sendstatus'),hist=document.getElementById('senthist');
          if(!btn)return;
          var MAX=65536,timer,KEY='ls_sent';
          function flash(msg,ok){
            st.textContent=msg;st.className='sendstatus '+(ok?'ok':'err');
            clearTimeout(timer);timer=setTimeout(function(){st.textContent='';st.className='sendstatus';},3000);
          }
          function load(){try{return JSON.parse(localStorage.getItem(KEY))||[]}catch(e){return[]}}
          function save(a){try{localStorage.setItem(KEY,JSON.stringify(a))}catch(e){}}
          // 历史项新版存 {t:文本, d:发送时刻ms}；旧版只存字符串，读取时归一（无时间戳 d=0、时间留空）。
          function norm(it){return (typeof it==='string')?{t:it,d:0}:it;}
          function pad(n){return (n<10?'0':'')+n;}
          // 紧凑相对时间（右侧角标，控长度）：24h 内 HH:MM；一年内 MM/DD；更久 YYYY；无时间戳留空。
          function fmtTime(d){
            if(!d)return '';
            var then=new Date(d),diff=Date.now()-d;
            if(diff<864e5)return pad(then.getHours())+':'+pad(then.getMinutes());
            if(diff<31536e6)return pad(then.getMonth()+1)+'/'+pad(then.getDate());
            return ''+then.getFullYear();
          }
          function render(){
            if(!hist)return; hist.innerHTML='';
            var a=load(); if(!a.length)return;
            var h=document.createElement('div');h.className='sh-title';h.textContent=LS_I18N.sentHistory;hist.appendChild(h);
            a.slice(0,20).forEach(function(item){
              var it=norm(item);
              var row=document.createElement('div');row.className='sh-item';
              var tx=document.createElement('span');tx.className='sh-text';tx.textContent=it.t;   // textContent 注入，安全
              var tm=document.createElement('span');tm.className='sh-time';tm.textContent=fmtTime(it.d);
              row.appendChild(tx);row.appendChild(tm);
              row.addEventListener('click',function(){ta.value=it.t;ta.focus();});
              hist.appendChild(row);
            });
          }
          function remember(v){var a=load();a.unshift({t:v,d:Date.now()});if(a.length>20)a=a.slice(0,20);save(a);render();}
          function fail(r){
            btn.disabled=false;
            r.text().then(function(b){
              var msg=''; try{msg=(JSON.parse(b)||{}).error||''}catch(e){}
              if(!msg)msg=(r.status===403?LS_I18N.sendStale:(r.status===413?LS_I18N.sendOverLimit:LS_I18N.sendFailed));
              flash(msg,false);
            },function(){flash(r.status===403?LS_I18N.sendStale:LS_I18N.sendFailed,false);});
          }
          function send(){
            var v=ta.value;
            if(!v.trim())return;
            if(new Blob([v]).size>MAX){flash(LS_I18N.sendOverLimit,false);return;}
            btn.disabled=true;
            fetch('/ls/text',{method:'POST',headers:{'Content-Type':'text/plain;charset=utf-8'},body:v})
              .then(function(r){
                if(r.ok){btn.disabled=false;ta.value='';remember(v);flash(LS_I18N.sent,true);ta.focus();}
                else fail(r);
              },function(){btn.disabled=false;flash(LS_I18N.sendNetwork,false);});
          }
          btn.addEventListener('click',send);
          ta.addEventListener('keydown',function(e){if((e.metaKey||e.ctrlKey)&&e.key==='Enter'){e.preventDefault();send();}});
          render();
        })();
        """

    // 独立发送页：自带极简外壳（票据风 tokens + 15s 心跳保活），正文是无标题区的发送卡片
    //（页面 H1 已承担标题）。与列表页同源同 tokens；不引外部依赖，局域网离线可渲染。
    static func html(lang: Lang) -> String {
        """
        <!doctype html><html lang="\(lang.htmlLang)"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <title>\(esc(L.webSendTitle(lang)))</title>
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
        h1{margin:0;font:600 34px/1.15 var(--serif);letter-spacing:-.02em;word-break:break-word}
        .sub{margin:10px 0 0;font:13.5px/1.6 var(--sans);color:var(--inkMute)}
        .card{background:var(--surface);border:1px solid var(--line);border-radius:14px}
        .colophon{text-align:center;margin-top:24px;font:12px var(--sans);color:var(--inkFaint)}
        .colophon b{font:600 12px var(--serif);color:var(--inkMute)}
        @media(max-width:560px){main{padding:18px 18px 24px}h1{font-size:26px}}
        \(css)
        </style></head><body>
        <main>
          <div class="kicker"><span class="dot"></span><span>\(esc(L.webSendEyebrow(lang)))</span></div>
          <h1>\(esc(L.webSendTitle(lang)))</h1>
          <p class="sub">\(esc(L.webSendSub(lang)))</p>
          \(card(lang: lang, withHead: false))
          <div class="colophon">\(L.webProvidedBy(lang))</div>
        </main>
        <script>var LS_I18N=\(LStr.i18nJSON(lang));</script>
        <script>
        (function(){function ping(){fetch('/ls/ping',{cache:'no-store'}).catch(function(){})}ping();setInterval(ping,15000);})();
        \(boot)
        </script>
        </body></html>
        """
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
