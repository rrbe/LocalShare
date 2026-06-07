# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目本质

macOS 原生单窗口 app（Swift / SwiftUI）：选一个文件夹 → 窗口出现二维码 → 同 WiFi 下的手机扫码即可在浏览器里只读浏览该文件夹。核心约束是**零外部动态依赖**——最终 `.app` 只链接系统框架，第三方库（Swifter）以 SPM 源码形式静态编进二进制。这条戒律的由来与全部设计决策见 `PLAN.md`（权威交接文档，跟随 git）。

## 常用命令

```bash
swift build                      # debug 编译（首次拉 Swifter）
swift build -c release           # release 编译
./build.sh                       # release 编译 → 组装 .app → ad-hoc 签名 → dist/LocalShare.app
open "dist/LocalShare.app"    # 本机自测 GUI

# 无头端到端测试（无 GUI，供脚本/curl 验证服务端逻辑）
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"   # 应返回目录列表或 index.html

# 验证核心戒律：otool 过滤系统库后应无任何输出（零第三方 dylib）
otool -L "dist/LocalShare.app/Contents/MacOS/LocalShare" | grep -v "/usr/lib/\|/System/Library/"
```

无测试框架（无 XCTest target）。验证靠无头模式 + `curl` 冒烟测：token 校验、防穿越、index.html、MIME、中文/空格文件名、流式发送。要求 macOS 13+ 与 Swift 工具链。

## 架构

入口在 `App.swift` 的 `@main enum EntryPoint`：`LS_HEADLESS=1` 走 `HeadlessServer`（裸起服务），否则跑 `LocalShareApp`（SwiftUI）。GUI 与测试共用同一个 `FileServer`，这是两条路径不分叉的关键。

数据流单向：`AppState`（`@MainActor ObservableObject`，唯一真相源）持有 `FileServer`、网络候选、派生出 `primaryURL` → `qrImage`；`ContentView` 只读渲染。`AppState` 负责生命周期——init 时从 `UserDefaults` 恢复上次文件夹并**自动 start**（同事开 app 即见码）；选目录用 `NSOpenPanel`。

`FileServer` 是核心，全部请求逻辑塞在**单个 Swifter middleware 闭包**里（永远返回 response，绕开 router）。每个请求依次过：① token 鉴权（`?t=` 或 cookie `ls_token`，靠 query 放行时种 cookie）→ ② 防目录穿越 → ③ 目录（无斜杠先 301、有 `index.html` 发它、否则 `DirectoryListing` 列表页）→ ④ 文件 64KB 分块流式。

辅助模块各自单一职责：`NetworkInfo`（`getifaddrs` 枚举 → 只留私网 IPv4、过滤 VPN/bridge/回环、en0 优先排序）、`QRCode`（CoreImage `CIQRCodeGenerator`）、`Token`、`Mime`（text 类带 `charset=utf-8`）、`DirectoryListing`（移动端友好 HTML，href 逐段编码、隐藏文件不列）。

## 跨文件的关键约束（改动前必读）

- **零 dylib 戒律不可破**：新依赖必须是纯 Swift 源码包，不能引入任何 `.dylib`。改完用上面的 `otool` 命令验证。这是项目存在的理由（dufs 当年就死在运行时缺 `liblzma.5.dylib`）。
- **Swifter 1.5.0 的 path 二次编码 bug**：`req.path` 落地文件系统前**仍残留一层百分号编码**，必须 `removingPercentEncoding` 解码（见 `FileServer.handle`）。纯 ASCII 路径无 `%` 故 `a.html` 正常，但 `b%20c.txt`、中文名不解码会 404。防穿越用的也是解码后的路径，所以 `%2e%2e` 同样被挡。
- **防穿越逻辑**（`FileServer.handle` 第 2 步）：拼接后 `standardizedFileURL.resolvingSymlinksInPath`，结果必须 `== rootPath` 或 `hasPrefix(rootPath + "/")`。动这段务必重跑穿越用例（`../`、`%2e%2e`、`..%2f`）。
- **线程模型**：Swifter 请求回调跑在后台 socket 线程，`AppState` 在 `@MainActor`。两者唯一共享的可变状态是 `FileServer.root`（运行中“更换文件夹”会改它），已用 `NSLock` 保护——换文件夹时**不重启 server**，token/cookie 保持有效。Package 用 Swift 5 语言模式正是为放宽这里的并发检查。
- **`.raw` 响应无 keep-alive**（body length 未知，发完即关），所以文件响应主动写 `Content-Length`（让手机显示进度）。LAN 静态分发无 keep-alive 足够。


## Git 工作流

当前阶段所有新功能/改动**直接提交到 `master`**，不开分支、不走 PR（覆盖全局 `~/.claude/CLAUDE.md` 的分支/PR 规则）。提交信息仍遵循 Conventional Commits（`feat:` / `fix:` / `docs:` …）。

## 强约束

- 设计功能模块时，如果能通过设计语言暗示用户的，就不要加过多文案。如果非要加文案，注意检查不要使用非常见词组和造句方式。
