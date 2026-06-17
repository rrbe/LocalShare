# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目本质

macOS 原生单窗口 app（Swift / SwiftUI）：选一个文件夹 → 窗口出现二维码 → 同 WiFi 下的手机扫码即可在浏览器里只读浏览该文件夹（可按需开启访客上传，默认只读）。核心约束是**不依赖任何包外动态库**——dufs 当年死于运行时缺失的 Homebrew dylib（`/opt/homebrew/...liblzma.5.dylib`，换台机器就没）。因此戒律的**精神**是「换任何机器都不会缺库」：系统框架照常链接；纯 Swift 第三方库（Swifter）以 SPM 源码静态编进二进制；**二进制 framework（Sparkle）以 `@rpath` 内置进 `.app/Contents/Frameworks/`、随包走、永不缺失**——这是 0.3 起放宽后的边界。绝对路径包外 dylib（`/opt/homebrew`、`/usr/local`）一律禁止。由来与全部设计决策见 `PLAN.md`（权威交接文档，跟随 git）。

## 常用命令

```bash
swift build                      # debug 编译（首次拉 Swifter）
swift build -c release           # release 编译
swift test                       # 单元测试（XCTest，纯函数：防穿越判据 / 文件名清洗 / key 去重）
./build.sh                       # release 编译 → 组装 .app → ad-hoc 签名 → dist/LocalShare.app
open "dist/LocalShare.app"    # 本机自测 GUI

# 无头端到端测试（无 GUI，供脚本/curl 验证服务端逻辑）
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"   # 应返回目录列表或 index.html

# 命令行调用（argv 路径；改 CLI/HeadlessServer 后务必用 release 复测，有已注释的 -O 编译器坑）
.build/debug/LocalShare --headless /path/a.html /path/dir   # 前台起服务，打印 LS_URL + 终端二维码
.build/debug/LocalShare a.html b.pdf                        # 转发给 GUI app（拉起或复用实例）
ln -s "$PWD/dist/LocalShare.app/Contents/MacOS/LocalShare" /tmp/localshare  # symlink 冒烟
/tmp/localshare --version                                   # 不崩 = dyld 经 realpath 找到包内 Sparkle

# 验证核心戒律：过滤系统库后，剩余依赖只能是 @rpath 引用、且对应 framework 确在包内
# Contents/Frameworks（如 Sparkle.framework）；出现任何绝对路径包外 dylib 即违规。
# build.sh / CI 已内置同款逐条校验，这里是手动复核：
otool -L "dist/LocalShare.app/Contents/MacOS/LocalShare" | grep -v "/usr/lib/\|/System/Library/"
# 期望：仅 @rpath/Sparkle.framework/... ；ls dist/LocalShare.app/Contents/Frameworks 应见 Sparkle.framework
```

测试分两层：`swift test`（XCTest，`Tests/LocalShareTests/`，测纯函数——防穿越判据 `resolveWithinRoot`、上传文件名清洗 `sanitizeFileName`、多选 key 去重 `Share.makeItems`、重名兜底 `availableURL` 等；用 `@testable import LocalShare` 直接碰可执行 target 的 internal 符号，无须拆 library）+ 无头 `curl` 冒烟测（`tools/smoke-*.sh` 与 `smoke-*.cjs`，端到端验 token 校验与 302 清洗、防穿越与单文件隔离、中文/空格/百分号文件名解码、多选虚拟根路由、上传去势、网卡绑定、Markdown 链接卫生）。两层都由 `.github/workflows/ci.yml` 在每个 PR / master push 上自动跑（`release.yml` 只管发版，互不干扰）。要求 macOS 13+ 与 Swift 工具链。

## 架构

入口在 `App.swift` 的 `@main enum EntryPoint`，三层分流：`LS_HEADLESS=1` 走 `HeadlessServer`（裸起服务）→ `CLI.parse` 命中 argv（`localshare <路径>…` / `--headless`）走 `CLI.run` → 否则跑 `LocalShareApp`（SwiftUI）。三条路径共用同一个 `FileServer`，这是逻辑不分叉的关键。CLI 默认把路径经 `NSWorkspace.open(urls, withApplicationAt:)` 转发给 GUI（`AppDelegate.application(_:open:)` 接收 → `AppState.setShared` 热切换；open 事件早于 `AppState` 构造时缓冲在 `pendingOpenURLs`）；`--headless` 则本进程前台起服务并打印终端二维码。`localshare` 命令本体是设置面板安装的 symlink（`CLIInstaller`），指向包内主二进制——dyld 解析 `@executable_path` 前会 realpath，故包内 Sparkle 照常加载；但 CLI 进程内**不可用 `Bundle.main`** 定位 .app（详见 `PLAN.md`「命令行启动」与 `HeadlessServer.runForeground` 上方注释的 release 编译器坑）。

数据流单向：`AppState`（`@MainActor ObservableObject`，唯一真相源）持有 `FileServer`、网络候选、派生出 `primaryURL` → `qrImage`；`ContentView` 只读渲染。真相源是 `sharedItems: [URL]`（0=空、1=单项、N=多选），派生 `isMultiple`/`isEmpty`/`sharedURL`(首项便利)。`AppState` 负责生命周期——init 时从 `UserDefaults` 恢复上次分享（多选存 `lastSharedPaths` 数组、旧单值键 `lastFolderPath` 作迁移回退，缺失项剔除）并**自动 start**（同事开 app 即见码）；选文件/夹用 `NSOpenPanel`（`allowsMultipleSelection = true`），拖拽收齐所有 provider 后一次提交。`RecentShare` 用 `paths: [String]` 记录多选、自定义 `init(from:)` 兼容旧单 `path` 记录。

`FileServer` 是核心，全部请求逻辑塞在**单个 Swifter middleware 闭包**里（永远返回 response，绕开 router）。`Share` 三态 `.directory` / `.file` / `.multiple([Item])`。请求先过 ① token 鉴权（`?t=` 或 cookie `ls_token`，靠 query 放行时种会话 cookie，浏览器导航（Accept 含 `text/html`）随即 302 到去掉 `?t=` 的干净 URL（token 不留地址栏/历史；curl 与 `*/*` 子请求不触发，测 `smoke-token-302.sh`）；**token 随每次「分享」动作轮换**——`setShared`/`stop` 即作废旧链接与旧 cookie，权限不跨分享延续），鉴权后顺手按客户端 IP 记 lastSeen 并 best-effort 后台反查设备名（`getnameinfo`，缓存 `nameCache`、串行队列、对端自报名清洗去控制/RTL 码点、随 token 轮换清零）（在线感知：45s 窗口内活跃 IP 即「N 人正在浏览」；GUI 由 `AppState` 2s 轮询展示在线情况（摘要行：反查到设备名才领衔具名（单台直呼其名、多台「领衔 + 等 N 人」），查不到统一「N 人正在浏览」、**不在摘要露 IP**；点摘要行弹 `ViewerListPopover` 列出全部在线访客——查到名字显名、查不到显**完整 IP**，并各带本次会话开始时长（`ViewerInfo.since`，源自 `firstSeen`）；`activeViewerInfos`→`ViewerInfo`（`fullLabel` 供列表））；`/ls/ping` 为保留心跳路径、先于分享内容命中，listing 页 JS 每 15s 打一次、**只回人数不外泄设备名**），再按形态分流：单文件直接发那一个文件、不暴露同目录其它；单文件夹与多选里的每个目录项共用 `serveTree(rootURL:relPath:…)`——② 防目录穿越（每项各自为根）→ ③ 目录（无斜杠先 301、有 `index.html` 发它、否则 `DirectoryListing` 列表页）→ ④ 文件 64KB 分块流式；例外是 `.md(.markdown)`/`.json(.geojson)`/`.csv(.tsv)` 的**浏览器导航**（Accept 含 `text/html` 且无 `?raw=1`）发预览壳页——壳页与文件**同 URL**（正文相对引用 `assets/x.png`、相邻 md 链接靠浏览器解析直接命中常规服务，勿改成 `/ls/preview` 之类保留路径），客户端渲染（md 用内嵌 vendored marked、原始 HTML 转义不执行 + 链接/图片协议白名单挡 `javascript:`（`MarkdownViewer.rendererConfig`，测 `smoke-md-link-sanitize.cjs` 跑真实 marked）；json 折叠树、csv 表格为手写零依赖，大数据靠懒构建/分档渲染），新增预览类型在 `FileServer.previewHTML` 登记；curl/壳页取文 fetch（Accept `*/*`）与 `?raw=1` 一律拿原文。**多选**无共同磁盘根，合成**虚拟根**：空路径发 `DirectoryListing.html(items:rootName:)` 列出选中项，其余请求拆**首段 `key`** 映射到真实 URL（`Share.makeItems` 以 lastPathComponent 为 key、跨目录拖拽重名以 `-2` 兜底）；未知 key 或文件项带子路径 → 404。**访客上传**（`Permission.add`，0.6）：`uploadEnabled` 开关（与 share 同锁，仅单文件夹分享可开、换分享自动回只读），POST multipart 写到当前浏览目录——落点过同一套防穿越校验、文件名只取末段清洗、重名 -2、临时文件原子换名、500MB 上限 413；可执行文档扩展名（html/svg 家族，`executableDocExtensions`）落地追加 `.txt` 去势——堵「上传 index.html 顶替目录页致零点击存储型 XSS」（只作用于上传，磁盘自带静态站点不受影响；另全站响应加 `X-Content-Type-Options: nosniff`，回归测试 `tools/smoke-upload-defang.sh`）；落地后打 `com.apple.quarantine`（`markQuarantine`，分享者双击触发 Gatekeeper）（注意 Swifter 进 middleware 前已把 body 整段读进内存，上限只能事后拒绝；分片上传留给 v1.5）；`onUpload` 回调在 socket 线程，GUI hop 回 MainActor 出「新收到」卡片。网页措辞（kicker/colophon）经 `permSummary` 派生，绝不硬编码。**仅当前网络可见**：`FileServer.listenAddress` 非 nil 时只绑该块网卡的 IPv4（Swifter 原生 `listenAddressIPv4`，无须 fork），由 `AppState.bindSelectedOnly` 驱动（切网卡/开关不轮换 token 地重绑、IP 消失回退全接口、`inet_pton` 非法即抛错不静默绑全接口）；默认 nil=绑 `0.0.0.0`。Headless 测多选用 `LS_FOLDERS`（`:`/换行分隔），开上传加 `LS_UPLOAD=1`，指定绑定网卡加 `LS_BIND=<ip>`。

辅助模块各自单一职责：`NetworkInfo`（`getifaddrs` 枚举 → 只留私网 IPv4、过滤 VPN/bridge/回环、en0 优先排序）、`QRCode`（CoreImage `CIQRCodeGenerator`）、`Token`、`Mime`（text 类带 `charset=utf-8`）、`DirectoryListing`（移动端友好 HTML，href 逐段编码、隐藏文件不列）、`PreviewPage`（预览壳页共用骨架：tokens/刊头/取景框/心跳）+ `MarkdownViewer`/`JsonViewer`/`CsvViewer`（三类预览内容卡，面包屑复用 `DirectoryListing.breadcrumb`）、`MarkedJS`（vendored marked，Swift 字符串常量编进二进制而非资源 bundle——三条启动路径都无须定位资源文件，升级整文件替换）。

`Updater.swift` 封装 Sparkle 自动更新：`UpdaterController` 持 `SPUStandardUpdaterController`，仅 GUI 路径（`LocalShareApp`）构造，headless 完全不碰。配置全在 `bundle/Info.plist`（`SUFeedURL` / `SUPublicEDKey` / `SUEnableAutomaticChecks`）。信任链走 EdDSA（私钥签更新包、app 内嵌公钥校验），与 ad-hoc 代码签名无关，故未公证也能安全自更新；`UpdaterController` 一律启动 updater、设置页一律展示「自动更新」开关，不按构建是否签名 / 配齐做预判（配置缺失顶多让 Sparkle 自己报错，不提前隐藏）。CI 发布时用 `sign_update` 签 DMG，`appcast.xml` 作为 Release 资产上传（feed 走 `releases/latest/download` 固定地址，发布对仓库零写入）。详见 `PLAN.md` 的「自动更新」一节。

## 发布与版本

版本号以 git tag 为准（`vX.Y.Z`，打在 master tip 上）：`bundle/Info.plist` 里的 `CFBundleShortVersionString` 只是占位值，CI 构建时用 tag 版本覆写、`CFBundleVersion` 写 run number，这个改写不会提交回 master——所以本地构建显示旧版本号是正常的，**发版不需要改 Info.plist**。发布步骤：变更全部合入 master → changelog 写进 annotated tag 的注释（`git tag -a vX.Y.Z -F notes.md`）→ 推 tag，`.github/workflows/release.yml`（监听 `v*`）接手：编译 universal → 依赖校验 → 打 DMG → 建 GitHub Release → EdDSA 签名 + 生成 `appcast.xml` 作为 Release 资产上传。appcast 不进 git：Sparkle feed 是 `https://github.com/rrbe/LocalShare/releases/latest/download/appcast.xml`（GitHub 保证恒指向最新 release 的同名资产），发布对仓库零写入，与 master 的「必须走 PR」规则互不相干。一次性迁移已随 v0.7.0 完成：仓库根的 `appcast.xml` 最后一次更新到 0.7.0 后冻结，只服务 ≤0.6.0 老客户端（其 feed 指向 raw master），它们升到 0.7.0 即转入新 feed；确认无老客户端存量后此文件可删。workflow 跑的是 tag 指向那个提交里的文件，所以改 release.yml 要先合入 master 再打 tag。changelog 写法：tag 注释里只写 `-` 列表，一个功能一条、用面向用户的说法、重要的放前面；不要写 `#` 标题行（`git tag` 默认会把 `#` 开头的行当注释删掉，「更新内容」这个标题由 workflow 加）；范围用 `git log v上一版..origin/master --oneline` 圈定。Release 正文由 workflow 拼成：版本简介 + 更新内容（tag 注释）+ 固定安装说明。

## 跨文件的关键约束（改动前必读）

- **不依赖包外 dylib（戒律的精神，不可破）**：判据是「换任何机器都不会缺库」。纯 Swift 依赖优先以 SPM 源码静态编进二进制；确需二进制 framework（如 Sparkle）时，必须 `@rpath` 引用并由 `build.sh` 内置进 `Contents/Frameworks/`、深度签名、且通过依赖校验（见 build.sh 末尾与 CI）。**绝对路径包外 dylib（`/opt/homebrew`、`/usr/local` 等）一律禁止**——这正是 dufs 当年崩在运行时缺 `liblzma.5.dylib` 的坑。新增/改依赖后务必跑上面的 `otool` 复核 + 确认 framework 已随包。
- **Swifter 1.5.0 的 path 二次编码 bug**：`req.path` 落地文件系统前**仍残留一层百分号编码**，必须 `removingPercentEncoding` 解码（见 `FileServer.handle`）。纯 ASCII 路径无 `%` 故 `a.html` 正常，但 `b%20c.txt`、中文名不解码会 404。防穿越用的也是解码后的路径，所以 `%2e%2e` 同样被挡。
- **防穿越逻辑**（`FileServer.handle` 第 2 步）：拼接后 `standardizedFileURL.resolvingSymlinksInPath`，结果必须 `== rootPath` 或 `hasPrefix(rootPath + "/")`。动这段务必重跑穿越用例（`../`、`%2e%2e`、`..%2f`）。
- **线程模型**：Swifter 请求回调跑在后台 socket 线程，`AppState` 在 `@MainActor`。两者共享的可变状态是 `FileServer` 的 `share` / `token` / `uploadEnabled` / `lastSeen` / `nameCache` / `nameLookupInFlight`（运行中「更换分享」会改前两者；设备名反查的缓存与在查 IP 集同锁保护），同一把 `NSLock` 保护——换分享时**不重启 server**（端口不变），但 **token 即刻轮换**：先换钥匙再换内容（杜绝旧 token 瞬间可读新分享），旧链接/cookie 作废、访客需重扫新码。Package 用 Swift 5 语言模式正是为放宽这里的并发检查。
- **`.raw` 响应无 keep-alive**（body length 未知，发完即关），所以文件响应主动写 `Content-Length`（让手机显示进度）。LAN 静态分发无 keep-alive 足够。

## 强约束

- 设计功能模块时，如果能通过设计语言暗示用户的，就不要加过多文案。如果非要加文案，注意检查不要使用非常见词组和造句方式。
