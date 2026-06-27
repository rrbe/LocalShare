# LocalShare · 架构（ARCHITECTURE）

> macOS 原生单窗口 app：选一个文件夹 → 窗口出现二维码 → 同 WiFi 下的手机扫码即可在浏览器里只读浏览该文件夹（可按需开启访客上传与「传递文本」，默认只读）。

本文是**现状架构参考**——核心约束、工程结构、关键设计决策与实现要点，供任何机器 `git pull` 后据此继续。配套文档：视觉设计规范见根目录 `DESIGN.md`；发布与版本流程见 `CLAUDE.md`。

---

## 0. 核心戒律：不依赖包外 dylib

崩溃的典型根因是 arm64 二进制**运行时缺失动态库**——动态链接到某个包外 `.dylib`（指向 `/opt/homebrew/…`，换台没装的机器就没）。因此戒律的精神是**「换任何机器都不会缺库」**：

- 只链接系统框架；纯 Swift 第三方库（Swifter）以 SPM 源码**静态编进二进制**。
- **0.3 放宽**：自动更新需要的 Sparkle 只以二进制 framework 分发（含动态库 + XPC 服务 + helper app），无法源码静态编进。结论：允许把二进制 framework 以 `@rpath` **内置进 `.app/Contents/Frameworks/`**——它随包走、自包含、运行时永不缺失，完全规避「包外缺库」的失败模式。
- **判据**：禁止任何位于 `.app` 包外的 dylib（绝对路径如 `/opt/homebrew`、`/usr/local` 一律禁止）；只接受 `@rpath` 引用、且已验证存在于 `Contents/Frameworks/` 的内置 framework。`build.sh` 末尾与 CI 均逐条校验（过滤系统库后，剩余依赖只能是 `@rpath/X.framework` 且对应 framework 确在包内）。

---

## 1. 锁定的设计决策

| 维度 | 决策 |
|---|---|
| 平台 | 仅 macOS（Apple Silicon 为主），原生 `.app` |
| 网络 | 仅同一 WiFi（LAN），无隧道 / 无公网 / 无账号 |
| 技术栈 | Swift / SwiftUI，只链接系统框架，零包外 dylib 风险 |
| HTTP 服务 | Swifter（SPM 源码编进 app），只读静态服务为主 |
| 服务模型 | 三种分享形态：① 单文件夹 → 移动端友好目录列表（含 `index.html` 则直接显示它）；② 单文件 → 扫码直接打开、不暴露同目录其它文件；③ 多文件/目录 → 合成**虚拟根**列出选中项，首段路径映射到真实 URL。三者均防目录穿越，每项各自为根 |
| 鉴权 | 每次「分享」动作生成随机 token，内嵌进二维码 URL（`?t=…`）；首访校验后种会话 cookie，后续资源自动放行；换分享 / 停止即轮换，旧链接 / cookie / 二维码即刻作废，权限不跨分享延续；猜 `IP:端口` 的路人被 403 |
| 协议 | 明文 http。威胁模型：防「猜地址的路人」（token），不防同网嗅探与持链者转发——后者风险窗口随 token 轮换收敛到单次分享内。自签证书会把「扫码即用」变成证书警告页、伤核心体验，**不做** |
| 二维码 | 裸 LAN IP（智能选接口、多候选给下拉），CoreImage `CIQRCodeGenerator` 生成，无第三方库；窗口另显 `.local` 备选链接 + 可复制 URL |
| GUI | 单窗口：**功能主页**（拖拽/选择分享 + 传递文本入口 + 最近分享）→ 文件票据 / 传递文本 / 设置 / 历史**均为带返回的二级页** |
| 生命周期 | 冷启动**不**自动重播上次分享（开 app 落主页，上次分享留「最近分享」一键重发）· 关窗不退出（进程/服务续活、菜单栏唤回即回原状）· 端口自动选 · 退出才停服务 |
| 分发 | Xcode ad-hoc 签名；首次帮同事过一次 Gatekeeper（放行被持久记住） |
| 自动更新 | Sparkle（`@rpath` 内置 framework）· 后台检查、发现新版弹提示由用户确认 · 信任链走 **EdDSA 签名**（与 ad-hoc 代码签名无关，未公证也安全） |
| 沙盒 | **不开 App Sandbox**（内部手发、不上架），省掉沙盒对「读任意文件夹」的限制 |
| 国际化 | 简体中文 + English 双语，文案编进二进制（不依赖资源 bundle）；**两个解析域彼此独立**——原生 app 跟设置，网页**逐请求**按浏览器 `Accept-Language` |

---

## 2. 工程结构

```
LocalShare/
  Package.swift            # swift-tools-version:5.9（Swift 5 语言模式，放宽并发检查）
  Package.resolved         # Swifter pin 在 1.5.0
  build.sh                 # swift build -c release → 组装 .app → ad-hoc 签名 → dist/
  bundle/Info.plist        # .app 的静态 Info.plist 模板（Sparkle feed / 公钥 / 版本占位）
  README.md / README_CN.md # 英文默认 + 中文
  CLAUDE.md                # 给 Claude Code 的工作指引（根目录，必加载）
  DESIGN.md                # 视觉设计规范（颜色/字体/组件，被多处源码按 §x 引用）
  docs/
    ARCHITECTURE.md        # 本文件
    images/                # README 截图
  Sources/LocalShare/
    App.swift              # @main enum EntryPoint：分流 GUI / headless / CLI；含 LocalShareApp 与 AppDelegate
    AppState.swift         # @MainActor ObservableObject：唯一真相源（分享项/文本/服务/网络/在线感知/持久化），含 Share / RecentShare / ReceivedText
    ContentView.swift      # 单窗口 SwiftUI：主页 + 各二级页装配
    Components.swift       # 票据风 UI 组件库（接受 Theme 显式传入）
    Theme.swift            # 颜色/主题统一生成（浅/深色，强调色可切）
    FileServer.swift       # Swifter 封装：token 中间件 + 防穿越 + 目录/文件/多选 + 上传 + 在线感知
    Permission.swift       # 权限模型（read 常开 / add 访客上传）+ PermSummary 文案派生
    FileType.swift         # 扩展名分类（预览类型登记、可执行文档去势名单）
    DirectoryListing.swift # 目录列表页 HTML（移动端友好，href 逐段编码，隐藏文件不列）
    PreviewPage.swift      # 预览壳页骨架（与文件同 URL，心跳/取景框）
    MarkdownViewer / JsonViewer / CsvViewer  # 三类预览内容卡（md 用 vendored marked，json/csv 手写零依赖）
    MarkedJS.swift         # vendored marked，作为 Swift 字符串常量编进二进制
    SendTextPage / TextViewer  # 传递文本：发送页（手机→Mac）与文本预览壳页
    NetworkInfo.swift      # getifaddrs 枚举 → 私网 IPv4 候选 + .local 主机名
    QRCode.swift           # CoreImage 生成 QR → NSImage（+ 终端 ANSI 码）
    Token.swift / Mime.swift   # 随机 token / 扩展名→MIME（text 带 charset=utf-8）
    Lang.swift             # i18n：编进二进制的中英文案表（L / LStr / i18nJSON）
    HeadlessServer.swift   # LS_HEADLESS=1 无界面模式 + CLI 前台模式
    CLI.swift / CLIInstaller.swift  # 命令行入口（argv 解析、转发 GUI）+ symlink 安装
    Updater.swift          # Sparkle 自动更新封装（仅 GUI 构造，headless 不碰）
  Tests/LocalShareTests/   # XCTest 纯函数：防穿越 / 文件名清洗 / 多选 key / i18n / 文本
  tools/                   # 无头 + curl 冒烟脚本（traversal / filenames / multiselect / upload-defang / token-302 / md-link / accept-language / text…）
```

入口 `@main enum EntryPoint` 三层分流：`LS_HEADLESS=1` → `HeadlessServer`（裸起服务）→ `CLI.parse` 命中 argv → `CLI.run` → 否则 `LocalShareApp`（SwiftUI）。三条路径**共用同一个 `FileServer`**，逻辑不分叉。

---

## 3. 关键实现要点

### Swifter 1.5.0 API 与编码坑

- 全部请求逻辑塞进**单个 middleware 闭包**（永远返回 response，绕开 router）。`HttpResponse.raw(code, reason, headers, writer)` 控状态码 / 自定义头 / 流式写文件。
- ⚠️ **path 二次编码 bug**：Swifter 的 `HttpParser` 让 `request.path` 落地文件系统前**仍残留一层百分号编码**，必须 `removingPercentEncoding` 解码。纯 ASCII 路径无 `%` 故 `a.html` 正常，但 `b%20c.txt`、中文名不解码会 404。防穿越用的也是解码后的路径，所以 `%2e%2e` 同样被挡。
- `.raw` 的 body length 未知（发完即关、无 keep-alive），所以文件响应**主动写 `Content-Length`**（让手机显示进度）。LAN 静态分发足够。

### FileServer 请求处理（单 middleware）

1. **token 鉴权**：`?t=` 或 cookie `ls_token` 任一等于当前 token 即放行（每请求取一次快照，轮换瞬间不串）；靠 `?t=` 放行时种 `Set-Cookie: ls_token=…; HttpOnly`。浏览器导航（Accept 含 `text/html`）随即 **302** 到去掉 `?t=` 的干净 URL（token 不留地址栏/历史；curl 与 `*/*` 子请求不触发）。
2. **防目录穿越**：`decoded → 去前导 / → 拼到 root → standardizedFileURL.resolvingSymlinksInPath`，结果必须 `== root` 或 `hasPrefix(root + "/")`，否则 403。`standardizedFileURL` 解掉 `..`，编码点点（`%2e%2e`）因「先解码后标准化」一并挡住。
3. **目录**：无斜杠先 301（让相对资源解析）→ 含 `index.html` 发它 → 否则 `DirectoryListing` 列表页（绝对 href 逐段编码、隐藏文件不列、非根列表首行「返回上一级」）。
4. **文件**：按扩展名查 MIME（text 加 `charset=utf-8`），`FileHandle` 分块（64KB）流式发。例外：`.md`/`.json`/`.csv` 的**浏览器导航**发预览壳页（与文件**同 URL**，正文相对引用靠浏览器解析命中常规服务）；curl / `?raw=1` / `*/*` 一律拿原文。

单文件夹的 2~4 步抽成 `serveTree(rootURL:relPath:…)` 复用。**单文件**直接发那一个。**多选**（`Share.multiple([Item])`，`makeItems` 以 lastPathComponent 为 key、重名 `-2` 兜底）：空路径发虚拟根列表页，其余拆首段 `key` 映射真实 URL；未知 key / 文件项带子路径 → 404，穿越判据每项独立。

### 网页侧 XSS 硬化与卫生加固

被服务的内容跑在分享源（`http://本机:端口`）下，HTML/SVG 会被当同源页面执行脚本。防线：

1. **访客上传去势（主修）**：`sanitizeFileName` 对可执行文档扩展名（html/htm/xhtml/svg/svgz/mht… 见 `FileType`）追加 `.txt`，落地成 `text/plain`。专堵「上传 `index.html` 顶替目录页 → 别人点进该目录零点击执行脚本」这条存储型 XSS。**只作用于上传**——分享者磁盘上自带的静态站点（含 `index.html`）经 `.directory` 直接服务、不过 `sanitizeFileName`，照常渲染。
2. **全站 `X-Content-Type-Options: nosniff`**（纵深防御）：关掉 MIME 猜测，正确声明类型的文件零回归。
3. **Markdown 链接/图片协议白名单**（`MarkdownViewer.rendererConfig`）：`.md` 走 marked 预览、不经去势，故覆盖 marked 的 `link`/`image` 渲染器，只放行安全协议（`http`/`https`/`mailto`/`tel`，图片加 `data:`）与相对/锚点。两个易错点：**先解 HTML 实体再判**（挡 `&#106;avascript:`）；解码后剥掉码点 ≤32 的字符（挡 `java<TAB>script:`），冒号须在任何 `/ ? #` 之前才算协议。`tools/smoke-md-link-sanitize.cjs` 连同真实 vendored marked 跑断言。

配套：**token-302 清洗**（上面第 1 步）；**上传文件打 `com.apple.quarantine`**（分享者双击触发 Gatekeeper）。回归测试 `tools/smoke-upload-defang.sh`。

### 访客上传

`Permission.add` 开关（与 share 同锁，仅单文件夹分享可开、换分享自动回只读）。POST multipart 写到当前浏览目录——落点过同一套防穿越、文件名只取末段清洗、重名 `-2`、临时文件原子换名、500MB 上限 413。注意 **Swifter 进 middleware 前已把 body 整段读进内存**，上限只能事后拒绝（分片上传留给将来，见 §5）。`onUpload` 回调在 socket 线程，GUI hop 回 MainActor 出「新收到」卡片。

### 在线感知

鉴权后按客户端 IP 记 `lastSeen`（45s 窗口即「N 人正在浏览」），best-effort 后台反查设备名（`getnameinfo`，缓存 `nameCache`、串行队列、随 token 轮换清零）。`/ls/ping` 为保留心跳路径（先于分享内容命中），listing 页 JS 每 15s 打一次、**只回人数不外泄设备名**；GUI 由 `AppState` 2s 轮询展示（具名领衔、查不到统一「N 人正在浏览」、不在摘要露 IP，点摘要弹列表）。

### 仅当前网络可见

`FileServer.listenAddress` 非 nil 时只绑该网卡 IPv4（Swifter 原生 `listenAddressIPv4`，无须 fork），由 `AppState.bindSelectedOnly` 驱动（切网卡/开关不轮换 token 地重绑、IP 消失回退全接口、`inet_pton` 非法即抛错不静默绑全接口）；默认 nil = 绑 `0.0.0.0`。

### AppState 与生命周期

- 唯一真相源是 `sharedItems: [URL]`（0=空、1=单项、N=多选），派生 `isMultiple`/`isEmpty`/`sharedURL`。
- **冷启动不恢复分享**：init 不把上次分享读回 `sharedItems`，落主页、不自动起文件服务——开 app 把某文件夹悄悄端上 LAN 是隐患，与文本「重启不自动重播」同姿态。上次分享留「最近分享」（`RecentShare`，`paths: [String]` 记多选）。收件箱是显式开关，仍自动起服务。
- 只**关窗不退出**时进程与服务续活、`@StateObject` 整进程只建一次，唤回即回离开那屏（不过 init）。
- 端口偏好 `[8080, 8000, 8888, 9000]` 逐个 try，全失败再随机高位口。
- **分享变更不重启 server**（端口不变），加锁更新 `share` 与 `token`——**先换钥匙再换内容**，杜绝旧 token 瞬间可读新分享。

### 屏幕路由 / 二级页

`Screen` 枚举：`.share`（主页）/ `.file`（文件票据）/ `.text`（传递文本）/ `.settings` / `.history`。文件票据与传递文本同为带返回二级页，头部统一 `← + 标题 + ⚙`，品牌名只留主页。主页「正在分享」横幅（`ActiveShareBanner`）：文件后台续跑时顶部出可点行，一键回票据。

### App 入口 / Headless / CLI

- `localshare a.html b.pdf` 默认把路径经 `NSWorkspace.open(urls, withApplicationAt:)` 转发给 GUI（运行中实例复用、热切换不重启 server）；`--headless` 本进程前台起服务并打印终端二维码（`QRCode.ansi`）。
- `localshare` 命令本体是设置面板安装的 **symlink**，指向包内主二进制——dyld 解析 `@executable_path` 前会 realpath，故包内 Sparkle 照常加载；但 CLI 进程内**不可用 `Bundle.main`** 定位 .app（自取 `_NSGetExecutablePath` → 解 symlink → 上溯三级拿 `.app`）。
- ⚠️ **release 编译器坑**：`-O` 在「枚举载荷里的 `Optional<in_port_t>` → 函数内构造 `[in_port_t]` → 传入 `FileServer.start`」这条链上会错编出垃圾数组指针（release 必崩、debug 正常的 heisenbug）。规避：`runForeground` 直接收具体 `preferredPorts: [in_port_t]`，Optional 展开留在调用方。**动 CLI/HeadlessServer 必须用 release 重跑 `--headless` 冒烟。**

### 自动更新（Sparkle）

- 经 SPM `binaryTarget` 引入；`build.sh` 用 `ditto` 把 `Sparkle.framework` 拷进 `Contents/Frameworks/`，executableTarget 加 `-rpath @executable_path/../Frameworks`。inside-out 深度 ad-hoc 签名后 `codesign --verify --deep --strict` 校验。
- `Updater.swift` 的 `UpdaterController`（`@MainActor`）持 `SPUStandardUpdaterController`，仅 `LocalShareApp` 构造（headless 不碰）。配置全在 `Info.plist`（`SUFeedURL` / `SUPublicEDKey` / `SUEnableAutomaticChecks`）；`SUPublicEDKey` 仍是占位值时不启动 updater。
- **信任链走 EdDSA**（私钥签更新包、app 内嵌公钥校验），与代码签名/公证无关，故 ad-hoc + 未公证也能安全自更新；Sparkle 装的更新不带 quarantine，首装后续升级不再触发 Gatekeeper。
- CI（`release.yml`）：build → 依赖闸门 → 打 DMG → 建 Release → `sign_update` EdDSA 签 DMG → 生成 `appcast.xml` **作为 Release 资产上传**（不提交 git，发布对仓库零写入）。feed 即 `https://github.com/rrbe/LocalShare/releases/latest/download/appcast.xml`（GitHub 恒指向最新 release 的同名资产）。

### 传递文本

让「选内容→手机扫码」从磁盘文件扩到一段文本，**两条独立单向通道**（发出去的 `sharedText` 与收回来的收件箱互不相通）：

- **v1 Mac→手机（发文本）**：`AppState.sharedText: String?`，几乎全复用只读管线——文本只是又一种被 GET 的内容（保留命名空间 `/ls/text`，先于虚拟根 key 匹配）。可独立分享或挂进多选虚拟根；导航发 `TextViewer` 壳页、`?raw=1`/curl 发 `text/plain` 原文。手机页纯文本转义显示 + 大「复制」按钮（`execCommand` 回退——纯 http LAN 是非安全上下文、`navigator.clipboard` 不可用）+ http(s) 安全自动链接。
- **v2 手机→Mac（收文本）**：独立收件箱通道，不落盘、不依赖文件夹分享。闸门 `textInboxEnabled`（opt-in 默认关，不限分享形态，开了就把服务拉起）；`POST /ls/text` 收一段纯文本；列表页内嵌发送表单。**双上限挡内存**：单条 64KB + 收件箱 100 条挤旧（Swifter body 预读内存，必须双限）。`onReceiveText` socket 线程 hop 回 MainActor 入收件箱卡片，仅应用内提醒、不发系统通知。
- **token 改回会话维度**：`setSharedText` **不轮换 token**（否则每次更新文本会把正在看的对端刷掉、还误伤共存的文件分享链接），只在 `setShared`/`stop`/`clearShare`/`stopTextTransfer` 这些会话边界轮换。两个持久化开关各默认关（发的是自己粘的、收的是他人投递的，隐私语义不同）。

### 国际化（i18n）

- 全部用户可见文案做成**编进二进制的 Swift 字符串表**（`Lang.swift`），不依赖资源 bundle，三条启动路径都无须定位文件，升级整文件替换。
- **两个解析域彼此独立**：① 原生 app 语言来自设置（`AppState.langPref`：跟随系统 / 中文 / English，持久化）；② 网页**逐请求**由浏览器 `Accept-Language` 决定（`Lang.fromAcceptLanguage`：按 `q` 值降序、`q=0` 跳过），**绝不读 app 设置**。
- 文案分三类：静态走 `L`（`CaseIterable` 枚举键，`switch` 返回 `(zh, en)`，编译器强制穷尽）；插值/复数/语序差异走 `LStr`；网页 JS 侧拼接走 `LStr.i18nJSON`（`jsEscape` 把 `<` 转 `<`，挡 `</script>` 提前收尾）。加语言只需在 `L`/`LStr` 各补一支。

### 容错 UI

无 WiFi / 无私网 IP → 不画死码，提示「请先连接 WiFi」。首次 start 触发 macOS 防火墙提示 → 文案引导点**允许**（误点拒绝是「扫了码却打不开」头号原因）。二维码下常驻一行排错提示（同一 WiFi、未开访客/设备隔离）。空文件夹友好态。

---

## 4. 构建与运行

```bash
swift build -c release          # 编译（首次会拉 Swifter）
swift test                      # XCTest 纯函数单测
./build.sh                      # 组装并 ad-hoc 签名 → dist/LocalShare.app
open dist/LocalShare.app        # 本机自测

# 无头端到端（无 GUI，供脚本/curl 验服务端逻辑）
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"   # 应返回目录列表或 index.html
```

无头测多选用 `LS_FOLDERS`（`:`/换行分隔），开上传加 `LS_UPLOAD=1`，指定绑定网卡加 `LS_BIND=<ip>`，传递文本用 `LS_TEXT` / `LS_RECV`。两层测试（`swift test` + `tools/smoke-*.sh`）都由 `.github/workflows/ci.yml` 在每个 PR / master push 自动跑。

**发给同事**：把 `dist/*.app` 拷过去；**首次由你帮他打开一次**（双击被 Gatekeeper 拦 → 系统设置 → 隐私与安全性 → 点「仍要打开」，仅此一次）。

---

## 5. 非目标与未做

**明确不做：**

- Apple 公证（要 $99/年开发者号）；https + 自签证书（会把扫码即用变成证书警告页，与核心体验冲突）；跨网络隧道（cloudflared/ngrok/tailscale）。
- **在线编辑 / 删除**（访客在浏览器里改/删文件）：决定不做——手机浏览器编辑体验差、覆盖丢数据与误删风险高，价值不抵风险。访客上传已覆盖「手机→Mac」的主诉求。`Permission.edit` / `Permission.del` 恒 `false`。

**未做（可能将来）：**

- **上传分片**：绕开 Swifter「整段 body 进内存」的限制，前端切片逐片 POST、服务端按序 append + 末片原子换名，任意大小、内存恒定。落地后可放开 500MB 上限。
- **更准的设备名反查**：现为 best-effort `getnameinfo`，iPhone 多查不到、回退 IP；要更准需走 `DNSServiceQueryRecord` 的 mDNS PTR 查询，成本高且仍不保证命中。
