#!/usr/bin/env node
// 防回归冒烟测：Markdown 链接/图片协议白名单（堵 javascript: 等「点开即在分享页同源执行」的存储型 XSS）。
// 不复刻逻辑——直接从源码提取**真实 vendored marked**（MarkedJS.swift）+ **真实渲染配置**
// （MarkdownViewer.rendererConfig），在 node 里 require/eval 后跑断言；测的就是会发给浏览器的那份代码。
// 用法： node tools/smoke-md-link-sanitize.cjs    退出码 0=全过、1=有断言失败、2=提取/加载失败。
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');

const root = path.resolve(__dirname, '..');
const markedSwift = fs.readFileSync(path.join(root, 'Sources/LocalShare/MarkedJS.swift'), 'utf8');
const viewerSwift = fs.readFileSync(path.join(root, 'Sources/LocalShare/MarkdownViewer.swift'), 'utf8');

// marked 源：MarkedJS.source 的 #"""…"""# 原始字符串内容（逐字 JS，UMD/CommonJS 模块）
const markedSrc = (markedSwift.split('#"""')[1] || '').split('"""#')[0];
if (markedSrc.length < 1000) { console.error('提取 marked 源失败'); process.exit(2); }

// 渲染配置：MarkdownViewer.rendererConfig 的 """…""" 内容（含 marked.use 的链接/图片白名单）
const rendererConfig = ((viewerSwift.split('static let rendererConfig = """')[1] || '').split('"""')[0]);
if (!rendererConfig.includes('MD-RENDERER-CONFIG')) { console.error('提取 rendererConfig 失败'); process.exit(2); }

// require marked（写临时 .cjs 再 require，UMD 自挂 module.exports）
const tmp = path.join(os.tmpdir(), 'ls-marked-' + process.pid + '.cjs');
fs.writeFileSync(tmp, markedSrc);
let marked;
try { const lib = require(tmp); marked = lib.marked || lib; } finally { fs.unlinkSync(tmp); }
if (!marked || typeof marked.use !== 'function' || typeof marked.parse !== 'function') {
  console.error('marked 加载失败'); process.exit(2);
}

// 应用真实渲染配置（其为引用全局 marked 的 IIFE，注入为函数参数）
new Function('marked', rendererConfig)(marked);

let pass = 0, fail = 0;
const check = (name, cond) => { console.log((cond ? '  ✅ ' : '  ❌ ') + name); cond ? pass++ : fail++; };
const TAB = String.fromCharCode(9), NUL = String.fromCharCode(0);

console.log('── 危险协议链接被去 href（只剩不可点文字）');
const js = marked.parse('[点我](javascript:alert(1))');
check('javascript: 链接无 href', !/href="javascript:/i.test(js));
check('渲染成 blk 文字、保留文案', /class="blk"/.test(js) && /点我/.test(js));
check('大小写混淆 JaVaScRiPt: 被挡', !/href="/i.test(marked.parse('[x](JaVaScRiPt:alert(1))')));
check('内嵌 TAB 的 java<TAB>script: 被挡', !/href="/i.test(marked.parse('[x](java' + TAB + 'script:alert(1))')));
check('内嵌 NUL 的 java<NUL>script: 被挡', !/href="/i.test(marked.parse('[x](java' + NUL + 'script:alert(1))')));
check('vbscript: 被挡', !/href="vbscript:/i.test(marked.parse('[x](vbscript:msgbox(1))')));
check('链接里的 data: 被挡', !/href="data:/i.test(marked.parse('[x](data:text/html,foo)')));

console.log('── HTML 实体编码绕过被堵（marked 把实体原样写进 href，浏览器才解码）');
// 这些 .md 若不解码就判，会被白名单当成「无协议=相对链接」放行，浏览器解码后却变成 javascript: 执行。
check('十进制实体 &#106;avascript: 被挡', !/href="[^"]*avascript:/i.test(marked.parse('[x](&#106;avascript:alert(1))')));
check('十六进制实体 &#x6a;avascript: 被挡', !/href="[^"]*avascript:/i.test(marked.parse('[x](&#x6a;avascript:alert(1))')));
check('大写 &#X6A;avascript: 被挡', !/href="[^"]*avascript:/i.test(marked.parse('[x](&#X6A;avascript:alert(1))')));
check('前导零 &#0000106;avascript: 被挡', !/href="[^"]*avascript:/i.test(marked.parse('[x](&#0000106;avascript:alert(1))')));
check('命名实体冒号 javascript&colon: 被挡', !/href="javascript&colon;/i.test(marked.parse('[x](javascript&colon;alert(1))')));
check('数字实体冒号 javascript&#58;: 被挡', !/href="javascript&#58;/i.test(marked.parse('[x](javascript&#58;alert(1))')));
check('实体编码图片 &#106;avascript: 无 src', !/src="[^"]*avascript:/i.test(marked.parse('![i](&#106;avascript:alert(1))')));

console.log('── 白名单：非安全协议一律拦、tel: 放行');
check('ftp: 被挡（白名单外）', !/href="ftp:/i.test(marked.parse('[x](ftp://host/f)')));
check('tel: 放行', /href="tel:/.test(marked.parse('[t](tel:+123)')));

console.log('── 正常链接照常渲染（不误伤）');
check('https 链接保留 href', /href="https:\/\/example\.com"/.test(marked.parse('[ok](https://example.com)')));
check('相对路径链接保留 href', /href="\/foo\/bar"/.test(marked.parse('[rel](/foo/bar)')));
check('锚点链接保留 href', /href="#sec"/.test(marked.parse('[a](#sec)')));
check('mailto 链接保留 href', /href="mailto:/.test(marked.parse('[m](mailto:a@b.com)')));

console.log('── 图片：脚本协议挡、data:image 内联图放行（不误伤）');
check('javascript: 图片无 src', !/src="javascript:/i.test(marked.parse('![i](javascript:alert(1))')));
check('data:image 内联图保留', /src="data:image\/png/.test(marked.parse('![i](data:image/png;base64,iVBORw0KGgo=)')));
check('正常图片保留 src', /src="\/a\.png"/.test(marked.parse('![i](/a.png)')));

console.log('── 既有防线未回归：原始 HTML 仍被转义');
const raw = marked.parse('<script>alert(1)</script>\n\nhi');
check('原始 <script> 被转义不执行', !/<script>alert/.test(raw) && /&lt;script&gt;/.test(raw));

console.log('');
console.log('结果：PASS=' + pass + '  FAIL=' + fail);
process.exit(fail === 0 ? 0 : 1);
