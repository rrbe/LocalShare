import Foundation

// 无 token 的浏览器导航在访问码模式下落到此页。纯 HTML 表单保证局域网离线可用；访问码通过 POST body
// 提交，不进入 URL、历史或代理日志。页面只接收固定枚举错误，不回显用户输入。
enum AccessCodePage {
    enum ErrorState {
        case invalid
        case limited
    }

    static func html(lang: Lang, error: ErrorState? = nil) -> String {
        let errorHTML: String
        switch error {
        case .invalid:
            errorHTML = #"<p class="error">\#(escape(L.webAccessCodeInvalid(lang)))</p>"#
        case .limited:
            errorHTML = #"<p class="error">\#(escape(L.webAccessCodeLimited(lang)))</p>"#
        case nil:
            errorHTML = ""
        }
        return """
        <!doctype html><html lang="\(lang.htmlLang)"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <meta name="robots" content="noindex,nofollow">
        <title>\(escape(L.webAccessCodeTitle(lang)))</title>
        <style>
        :root{--accent:#df4f28;--accentSoft:rgba(223,79,40,.12);--bg:#efeae1;--surface:#fdfbf7;
          --field:#efe9de;--ink:#2a261d;--inkMute:#8c8475;--line:#e7dfd1;--danger:#c43c1c;
          --serif:"Source Serif 4",ui-serif,"Songti SC",Georgia,serif;
          --sans:-apple-system,BlinkMacSystemFont,"Segoe UI",system-ui,"PingFang SC",sans-serif;
          --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color-scheme:light dark}
        @media(prefers-color-scheme:dark){:root{--accentSoft:rgba(223,79,40,.18);--bg:#1b1814;
          --surface:#262219;--field:#1d1a14;--ink:#f2eee5;--inkMute:#a59d8c;--line:#37322a;
          --danger:#ef8a6e}}
        *{box-sizing:border-box}html,body{margin:0}body{min-height:100vh;display:grid;place-items:center;
          padding:24px;background:var(--bg);color:var(--ink);font:15px/1.5 var(--sans)}
        main{width:min(100%,420px)}.kicker{margin-bottom:12px;color:var(--accent);font:700 12px var(--sans);
          letter-spacing:.06em}h1{margin:0;font:600 32px/1.15 var(--serif);letter-spacing:-.02em}
        .card{margin-top:22px;padding:18px;background:var(--surface);
          border:1px solid var(--line);border-radius:16px}.field{display:flex;align-items:center;gap:10px;
          height:48px;padding:0 14px;background:var(--field);border:1px solid var(--line);border-radius:11px}
        input{width:100%;border:0;outline:0;background:transparent;color:var(--ink);text-transform:uppercase;
          text-align:center;font:700 20px/1 var(--mono);letter-spacing:.16em}button{width:100%;height:44px;margin-top:12px;
          border:1px solid var(--accent);border-radius:11px;background:var(--accent);color:white;cursor:pointer;
          font:600 14px var(--sans)}.error{margin:12px 2px 0;color:var(--danger);font-size:12.5px}
        </style></head><body><main>
          <div class="kicker">\(L.webProvidedBy(lang))</div>
          <h1>\(escape(L.webAccessCodeTitle(lang)))</h1>
          <form class="card" method="post" action="/ls/join" autocomplete="off">
            <label class="field"><input name="code" inputmode="text" maxlength="12" autofocus
              placeholder="\(escape(L.webAccessCodePlaceholder(lang)))" aria-label="\(escape(L.accessCodeLabel(lang)))"></label>
            <button type="submit">\(escape(L.webAccessCodeSubmit(lang)))</button>
            \(errorHTML)
          </form>
        </main></body></html>
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
