# LocalShare · 设计与实现计划（PLAN）

> 一个 macOS 原生单窗口 app：不懂技术的同事打开它、选一个文件夹，窗口中央出现二维码，
> 用 iPhone 扫一下就能在 Safari 里浏览/打开那个文件夹里的 html 等文件。
> 全程不碰终端、不装 Homebrew、不依赖任何动态库。

本文件是**可移植的交接文档**——跟随 git 走，任何机器 `git pull` 后都能据此继续。

---

## 0. 背景与核心戒律

- 起因：要让小白同事在手机上看电脑里的 html。iOS Safari 不能直接开本地文件，AirDrop 过去也打不开，必须有一个**本机进程监听端口**对外提供 HTTP。
- 纯浏览器技术栈做不到（无法 listen 端口 / 接受入站连接），所以必须是原生 app。
- **核心戒律**：dufs 的崩溃根因是 arm64 二进制**运行时缺失动态库**（动态链接了 Homebrew 的 `liblzma.5.dylib`，指向 `/opt/homebrew/...`，换台机器就没）。因此戒律的精神是**「换任何机器都不会缺库」**：只链接系统框架；纯 Swift 第三方库以 SPM 源码静态编进 app。Swift/SwiftUI + SPM 源码依赖天然满足。
  - **0.3 放宽**：自动更新需要 Sparkle，而 Sparkle 只以二进制 framework 分发（含动态库 + XPC 服务 + helper app），无法源码静态编进。结论：**允许把二进制 framework 以 `@rpath` 内置进 `.app/Contents/Frameworks/`**——它随包走、自包含、运行时永不缺失，完全规避 dufs 那种「包外缺库」的失败模式。判据据此从「零第三方 dylib」收紧为更准确的一条：**禁止任何位于 `.app` 包外的 dylib（绝对路径如 `/opt/homebrew`、`/usr/local` 一律禁止）；只接受 `@rpath` 引用、且已验证存在于 `Contents/Frameworks/` 的内置 framework**。`build.sh` 与 CI 均按此逐条校验（见下）。

---

## 1. 已锁定的设计决策

| 维度 | 决策 |
|---|---|
| 平台 | 仅 macOS（Apple Silicon 为主），原生 `.app` |
| 网络 | 仅同一 WiFi（LAN），无隧道/无公网/无账号 |
| 技术栈 | Swift / SwiftUI，只链接系统框架，零 dylib 风险 |
| HTTP 服务 | Swifter（SPM 源码编译进 app），只读静态服务 |
| 服务模型 | 三种分享形态：① 单文件夹 → 移动端友好目录列表（含 `index.html` 则直接显示它）；② 单文件 → 扫码直接打开、不暴露同目录其它文件；③ 多文件/目录 → 合成**虚拟根**列出这批选中项，首段路径映射到对应真实 URL、再落到该项内部。三者**均防目录穿越**，每个目录项各自为根锁死路径 |
| 鉴权 | 每次 app 启动生成随机 token，内嵌进二维码 URL（`?t=…`）；首访校验后种 cookie，后续资源自动放行；猜 `IP:端口` 的路人被 403 |
| 协议 | 明文 http（纯静态内容，无需 https/证书） |
| 二维码地址 | 裸 LAN IP（智能选接口、多候选给下拉）；窗口另显 `.local` 备选链接 + 可复制 URL |
| 二维码生成 | CoreImage `CIQRCodeGenerator`，无第三方库 |
| GUI | 单窗口：大二维码居中 + 可点/复制 URL + 当前文件夹/更换 + 启停状态 + 接口下拉 + “打不开?”排错行 |
| 生命周期 | 记住上次文件夹 · 开 app 自动起服务 · 端口自动选（占用则换）· 退出停服务 |
| 容错 | 检测无 WiFi/无 IP 并提示 · 首启引导点防火墙“允许” · 常驻排错提示 · 空文件夹友好态 |
| 分发 | Xcode ad-hoc 签名 · 你首次帮同事过一次 Gatekeeper（放行被持久记住） |
| 自动更新 | Sparkle（二进制 framework，`@rpath` 内置进 `Contents/Frameworks/`）· 自动后台检查、发现新版弹提示由用户确认 · 信任链走 **EdDSA 签名**（与 ad-hoc 代码签名无关，故未公证也安全）· appcast 托管在 `raw.githubusercontent.com/.../master/appcast.xml`，CI 每次发布重写并提交回 master |
| 沙盒 | **不开 App Sandbox**（内部手发、不上 App Store），省掉沙盒对“读任意文件夹”的限制 |

---

## 2. 工程结构

```
lan-file-share/
  Package.swift            # swift-tools-version:5.9（Swift 5 语言模式，放宽并发检查）
  Package.resolved         # Swifter pin 在 1.5.0
  PLAN.md                  # 本文件
  README.md
  build.sh                 # swift build -c release → 组装 .app → ad-hoc 签名 → 输出 dist/
  bundle/Info.plist        # .app 的静态 Info.plist 模板（build.sh 拷入）
  .gitignore               # .build/ dist/ *.app .DS_Store
  Sources/LocalShare/
    App.swift              # @main enum EntryPoint：分流 GUI/headless；含 LocalShareApp 与 AppDelegate
    AppState.swift         # ObservableObject：folder/server/urls/status/candidates，启停、选目录、持久化
    ContentView.swift      # 单窗口 SwiftUI：二维码 / URL / 文件夹 / 接口下拉 / 排错
    FileServer.swift       # Swifter 封装：token 中间件 + 防穿越 + index.html + MIME 流式
    DirectoryListing.swift # 目录列表页 HTML 生成（viewport、简洁 CSS、逐段编码的绝对 href）
    NetworkInfo.swift      # getifaddrs 枚举接口 → 私网 IPv4 候选；.local 主机名
    QRCode.swift           # CoreImage 生成 QR → NSImage
    Token.swift            # 随机 url-safe token
    Mime.swift             # 扩展名 → MIME 映射（text 类带 charset=utf-8）
    HeadlessServer.swift   # LS_HEADLESS=1 无界面模式（测试/自动化用）+ CLI 前台模式
    CLI.swift              # 命令行入口：argv 解析、转发 GUI（NSWorkspace）、--headless 分流
    CLIInstaller.swift     # /usr/local/bin/localshare symlink 的检测/安装（含 osascript 提权）
    Updater.swift          # Sparkle 自动更新封装（仅 GUI 构造，headless 不碰）
```

---

## 3. 关键实现要点（含已核对的 Swifter 1.5.0 API）

### Swifter API 事实（已核对源码，避免凭记忆踩坑）
- `HttpServer.middleware: [(HttpRequest) -> HttpResponse?]`——返回非 nil 即短路；我们把**全部逻辑放进一个 middleware 闭包**，永远返回 response，绕开 router。
- `HttpResponse.raw(Int code, String reason, [String:String]? headers, ((HttpResponseBodyWriter) throws -> Void)? writer)`——用它控制状态码 / 自定义头（Set-Cookie、Content-Type、Content-Length）/ 流式写文件。
- `HttpResponseBodyWriter.write(_ data: Data)`——按块写文件。
- ⚠️ `request.path` **不是干净解码的**：Swifter 的 `HttpParser` 先把请求目标用 `.urlQueryAllowed` 再编码一次（把已有的 `%` 变成 `%25`），再取 `URLComponents.path` 只解一层，**净结果是 `request.path` 仍残留一层百分号编码**。所以带空格/中文的路径必须在 FileServer 里再 `removingPercentEncoding` 解码后才能落地文件系统（纯 ASCII 路径无 `%`，故 `a.html` 正常而 `b%20c.txt` 不解码会 404）。
- `request.queryParams: [(String,String)]` 取 `t`；`request.headers`（key 小写）取 `cookie`。token 限定为 `[a-z0-9]`，不受上面的编码残留影响。
- `start(_ port: in_port_t, forceIPv4: Bool = false)` throws；端口占用会 throw → 我们循环换端口。绑定全接口（手机可达），用 `forceIPv4: true`。`stop()` 停服务。
- 注意：`.raw` 的 body length 未知（-1）→ respond() 不会自动加 Content-Length、连接发完即关（无 keep-alive）。故 FileServer 对文件**主动在 headers 写入 `Content-Length`**（已知文件大小，让手机显示进度）；LAN 上一把静态文件无 keep-alive 也完全够用。

### FileServer 请求处理流程（单 middleware 闭包）
1. **鉴权**：读 `?t=`，或读 cookie `ls_token`。任一等于本会话 token 即放行；都没有 → 返回 403 小页面。若靠 `?t=` 放行，则在响应里加 `Set-Cookie: ls_token=<token>; Path=/; Max-Age=86400; SameSite=Lax`。
2. **路径安全**（先解码，再防穿越）：
   ```
   decoded = request.path.removingPercentEncoding   // 修正上面的 Swifter 编码残留
   rel     = decoded 去掉前导 '/'
   root    = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
   target  = root.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath().path
   guard target == root || target.hasPrefix(root + "/") else { 403 }
   ```
   `standardizedFileURL` 解掉 `..`，杜绝 `GET /../../etc/passwd`；编码点点（`%2e%2e`）也因「先解码后标准化」被一并挡住。
3. **目录**：① 若请求的目录路径不以 `/` 结尾 → 先 301 加斜杠（让 `index.html` 里的相对资源能正确解析）；② 含 `index.html` → 发该文件；③ 否则发 DirectoryListing 列表页。列表 href 为**绝对路径并逐段百分号编码**（`encodePath`，保留 `/` 分隔符）；隐藏文件（`.` 开头）不列。
4. **文件**：按扩展名查 MIME（text 类加 `; charset=utf-8`，关键——中文 html 才不乱码），`FileHandle` 分块（64KB）`writer.write(Data)` 流式发。

> 单文件夹的 2~4 步抽成 `serveTree(rootURL:relPath:…)` 复用。**单文件**直接发那一个文件。**多选**（`Share.multiple([Item])`，`Item` 持 `key`/`url`/`isDir`，`makeItems` 由选中 URL 构造、key 取 lastPathComponent 并对极少数重名做 `-2` 后缀兜底）：空路径 → 合成虚拟根列表页（`DirectoryListing.html(items:rootName:)`，rootName=「分享内容」）；否则拆首段 `key` 查项——文件项仅当无子路径才发、目录项以 `item.url` 为根走 `serveTree`（`relPath`=去掉 key 段后的剩余，面包屑天然渲染成「分享内容 / key / …」）。未知 key / 文件项带子路径 → 404；穿越判据每项独立。Headless 测多选用 `LS_FOLDERS`（`:`/换行分隔）。

### NetworkInfo
- `getifaddrs` 遍历；取 `IFF_UP && !IFF_LOOPBACK && AF_INET`；`getnameinfo(NI_NUMERICHOST)` 拿 IP。
- 只留私网段：`192.168.*` / `10.*` / `172.16–31.*`（过滤掉 VPN/utun、bridge）。
- 排序：`en0`(WiFi) 优先，其次 `en*`，再其次其它；去重。
- `.local`：`ProcessInfo.processInfo.hostName`，确保以 `.local` 结尾再展示。

### QRCode
- `CIFilter.qrCodeGenerator()`，`message = url.data(.utf8)`，`correctionLevel = "M"`；`CGAffineTransform` 放大（避免糊）；`CIContext` → `CGImage` → `NSImage`。

### AppState / 生命周期
- `folderURL` 持久化到 `UserDefaults`（非沙盒，存路径字符串即可，无需 security-scoped bookmark）。
- 启动时若有记住的文件夹 → 自动 start。
- 端口选择：偏好列表 `[8080, 8000, 8888, 9000]` 逐个 try start，全失败再随机 49152–65535。
- 选目录用 `NSOpenPanel`（`canChooseDirectories = true`）。
- folder 变更：不重启 server，加锁更新 FileServer 的 root（token/cookie 保持有效）。
- token 每次 app 启动生成一次（QR 与校验共用）。

### App.swift / 入口
- `@main enum EntryPoint` 三层分流：`LS_HEADLESS=1` 走 `HeadlessServer.run()`（无界面，测试/自动化）→ `CLI.parse(CommandLine.arguments)` 命中则走 `CLI.run`（命令行调用，见下「命令行启动」）→ 否则 `LocalShareApp.main()` 跑 SwiftUI。
- `AppDelegate`（`NSApplicationDelegateAdaptor`，`@MainActor`）：`applicationDidFinishLaunching` 里 `NSApp.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)`（裸跑也能前台）；`applicationShouldTerminateAfterLastWindowClosed → false`（关窗不退出，菜单栏图标常驻）；`application(_:open:)` 接 CLI 转发的文件 → `AppState.setShared` + 唤窗。open 事件可能早于 `AppState` 构造（`@StateObject` 时机由 SwiftUI 决定），先存 `pendingOpenURLs` 缓冲、`AppState.init` 末尾消费。
- 唤窗链路：主窗已关时 `openWindow` 只能从活着的视图环境拿——`MenuBarExtra` 的 label 视图（`MenuBarIcon`）常驻菜单栏、监听 `.lsShowMainWindow` 通知代为 `openWindow(id: "main")`；`AppState.showMainWindow()` 只发通知。

### HeadlessServer（测试/自动化 + CLI 前台）
- `LS_HEADLESS=1` 时仅起 `FileServer` 并 `RunLoop.main.run()`，不拉 GUI。环境变量：`LS_FOLDER` / `LS_FOLDERS`（二选一）、`LS_TOKEN`（默认 `testtoken`）、`LS_PORT`（默认 8080）；启动后打印 `LS_URL …` 便于脚本读取。
- `runForeground(urls:preferredPorts:)` 是 `localshare --headless` 的前台模式：随机 token（`Token.generate()`，GUI 同款安全模型）、URL 用局域网 IP（`NetworkInfo`，手机要扫）、交互终端（isatty）下追加 ANSI 半块字符二维码（`QRCode.ansi`，黑码白底写死、深浅终端均可扫）、管道场景只输出 `LS_URL` 行。
- ⚠️ **编译器坑**：Swift 6.2.4 的 `-O` 在「枚举载荷里的 `Optional<in_port_t>` → 函数内构造 `[in_port_t]` → 传入 `FileServer.start`」这条链上会错编出垃圾数组指针（release 必崩 `Fatal error: failed to allocate …`，debug 正常，加 print 即消失的 heisenbug）。规避：`runForeground` 直接收具体 `preferredPorts: [in_port_t]`，Optional 的展开留在调用方 `CLI.run`。动这段必须用 **release** 构建重跑 `--headless` 带/不带 `--port` 的冒烟。

### 命令行启动（CLI，0.4）
- 形态：`localshare a.html b.pdf`（唤起/复用 GUI 分享这些路径）；`localshare --headless [--port N] <路径>…`（前台起服务不开窗）；`localshare` 不带参数仅唤起窗口；`--help` / `--version`。
- 安装物是 **symlink** `/usr/local/bin/localshare → LocalShare.app/Contents/MacOS/LocalShare`。可行性关键：dyld 解析 `@executable_path`（Sparkle 的 rpath）前会对主二进制 realpath，故经 symlink 启动包内 framework 照常加载（Sublime `subl` 同款机制，已实测 universal 包不崩）。
- argv 判定（`CLI.parse`，保证 Finder/LaunchServices 启动永不误入）：丢弃 `-psn_*`、`-NSDocumentRevisionsDebugMode` 噪音；识别 flag 与非 `-` 开头的路径参数；有 flag 或路径才算 CLI；未知 `-` 选项在 argv[0] 是 `localshare`（经 symlink）时报错 exit 2，否则视为 AppKit 噪音走 GUI。
- 转发 GUI：CLI 进程**不可用 `Bundle.main`**（经 symlink 启动时它可能按链接路径解析）——自取 `_NSGetExecutablePath` → 解 symlink → 上溯三级拿 `.app`，裸跑回退按 bundle id 查已安装 app；然后 `NSWorkspace.open(urls, withApplicationAt:)`（显式指定目标 app，无需 `CFBundleDocumentTypes`，运行中实例默认复用、热切换不重启 server、token/cookie 不失效）。CLI 进程只跑 `RunLoop` 等回调，**不碰 NSApplication**（否则 Dock 闪幽灵图标）。
- 安装器（`CLIInstaller`，设置面板「命令行工具」节）：状态三态 notInstalled / installed / stale（两侧 `resolvingSymlinksInPath` 后比对，stale 时面板直接亮出实际指向）；安装先直接 `createSymbolicLink`，权限不足转 `osascript … with administrator privileges`（路径双层转义；stderr 含 `-128` = 用户取消，静默返回）；卸载只删 symlink、同名真实文件不动。GUI 进程内 `Bundle.main` 可靠（永远由真实 .app 路径拉起）；但裸二进制（`swift run`）没有 .app 可指，`binaryPath()` 返回 nil → 面板收起「安装」按钮（状态/卸载照常），避免装出指向 `.build` 构建产物的链接（曾导致 CLI 定位不到 .app、转发落到旧版实例）。

### 自动更新（Sparkle）
- **依赖形态**：Sparkle 以二进制 framework 经 SPM `binaryTarget` 引入（`Package.swift` 里 `from: "2.6.0"`，实测解析到 2.9.3）。`swift build` 会把 `Sparkle.framework` 解到 `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/`（单切片已含 arm64+x86_64），同目录 `bin/` 还带 `sign_update` / `generate_keys` / `generate_appcast`。
- **内置与 rpath**：`Package.swift` 给 executableTarget 加了 `-rpath @executable_path/../Frameworks`；`build.sh` 用 `ditto` 把 framework 拷进 `Contents/Frameworks/`，于是 `Contents/MacOS/LocalShare` 经该 rpath 即能加载包内 framework（脱离 `.build` 也成立，已实测 headless 启动无 dyld 错误）。
- **签名**：`build.sh` inside-out 深度 ad-hoc 签名（`--deep` 签 framework 内的 XPCServices/Updater.app/Autoupdate/dylib → 再签整个 app），随后 `codesign --verify --deep --strict` 校验。
- **依赖校验**（`build.sh` 末尾 + CI）：逐条过滤主二进制依赖，系统库放行、`@rpath/X.framework` 必须对应 `Contents/Frameworks/X.framework` 存在、其余包外 dylib 判失败。
- **代码集成**：`Updater.swift` 的 `UpdaterController`（`@MainActor`）持 `SPUStandardUpdaterController`，在 `LocalShareApp` 以 `@StateObject` 构造（headless 路径不触及）；菜单 About 下方加「检查更新…」。配置全在 `Info.plist`：`SUFeedURL`、`SUPublicEDKey`、`SUEnableAutomaticChecks=true`、`SUScheduledCheckInterval=86400`、`SUAutomaticallyUpdate=false`（发现新版只提示、不静默装）。
- **信任链**：走 EdDSA（Ed25519）——更新包用私钥签名、app 内嵌 `SUPublicEDKey` 校验，**与代码签名/公证无关**，所以 ad-hoc + 未公证也能安全自更新。且 Sparkle 安装的更新不带 `com.apple.quarantine`，首次装好后续升级不再触发 Gatekeeper。
- **CI 链路**（`.github/workflows/release.yml`）：build → 依赖闸门 → 打 DMG → 建 Release → 用 `sign_update` 对 DMG 做 EdDSA 签名 → 生成单条 `<item>` 的 `appcast.xml`（enclosure 指向 Release 里的 DMG URL）→ `git checkout -f -B master` 后提交回 master。feed 即 `raw.githubusercontent.com/rrbe/LocalShare/master/appcast.xml`。

#### ⚠️ 发布前一次性配置（必做，否则自动更新不生效）
1. 本地装 Sparkle 工具后生成 EdDSA 密钥对：`./bin/generate_keys`（私钥进登录钥匙串，终端打印 base64 **公钥**）。
2. 把公钥填进 `bundle/Info.plist` 的 `SUPublicEDKey`，替换占位值 `REPLACE_WITH_REAL_SUPublicEDKey`，提交。（公钥非机密，直接进仓库。）
3. 导出私钥：`./bin/generate_keys -x private_key.pem`（或从钥匙串导出），把内容存为 GitHub 仓库 secret **`SPARKLE_ED_PRIVATE_KEY`**。**私钥绝不入仓库**。
   - 未配 secret 时 CI 会跳过 appcast 生成（仅出 DMG，发 `::warning::`）；`Info.plist` 仍是占位公钥时 app 不启动 updater。两道保险让「未配置」状态显式可见。

### 容错 UI
- 无 WiFi / 无私网 IP → 不画死码，显示“请先连接 WiFi”。
- 首次 start 触发 macOS 防火墙“是否允许接受传入连接”——UI 文案引导点**允许**（误点拒绝是现实中“扫了码却打不开”头号原因）。
- 二维码下常驻一行：“打不开？→ 确认两台设备在同一 WiFi，且该 WiFi 未开启‘访客/设备隔离’。”

---

## 4. 构建与运行

```bash
cd lan-file-share
swift build -c release          # 编译（首次会拉 Swifter）
./build.sh                      # 组装并 ad-hoc 签名 → dist/LocalShare.app
open dist/LocalShare.app     # 本机自测
```

**发给同事**：把 `dist/*.app` 拷过去；**首次由你帮他打开一次**（双击若被 Gatekeeper 拦，去“系统设置 → 隐私与安全性”点“仍要打开”，仅此一次，之后他双击即用）。

---

## 5. 进度

- [x] 项目脚手架 + `Package.swift` + Swifter 1.5.0 解析
- [x] Swifter API 核对
- [x] 本计划文档
- [x] 源码：Token / Mime / NetworkInfo / QRCode / DirectoryListing / FileServer / AppState / ContentView / App / HeadlessServer
- [x] `bundle/Info.plist` + `build.sh` + `.gitignore` + `README`
- [x] `swift build` 编译通过
- [x] `curl` 冒烟测全通过：token 校验（无/错→403，对→200+Set-Cookie）、目录列表（隐藏文件不列）、
      index.html 自动显示、无斜杠目录 301、文件 MIME（charset=utf-8）、中文/空格文件名、文件流式
- [x] 安全：目录穿越（字面 `..`、编码 `%2e%2e`、混合 `..%2f`）全部 403，`/etc/passwd` 不可达
- [x] 组装 `.app`：codesign 有效；`otool -L` 确认**零第三方 dylib**（仅 /usr/lib 与系统 Frameworks）
- [x] GUI 端到端：启动 → 读记住的文件夹 → 自动起服务 → 监听端口生效
- [x] 自动更新（Sparkle）：framework `@rpath` 内置进 `Contents/Frameworks/` + 深度签名；放宽后依赖闸门（build.sh/CI）只许内置 framework；`Updater.swift` + Info.plist 配置；CI 走 EdDSA 签名 + appcast 提交回 master。**发布前需一次性配置 EdDSA 密钥**（见 §3「发布前一次性配置」）。
- [x] 命令行启动：`localshare <路径>…` 转发 GUI / `--headless` 前台模式 / 设置面板安装 symlink；
      已验证 symlink 经 dyld realpath 加载包内 Sparkle、冷启动 open 事件缓冲、热切换实例复用、
      终端二维码 Vision 实扫解码通过；release 编译器坑已规避并注释（见 §3「命令行启动」）。

> 已知坑（已规避并注释）：Swifter 1.5.0 的 `HttpParser` 会对请求 path 二次编码，导致 `request.path`
> 仍残留一层百分号编码 —— FileServer 落地文件系统前已用 `removingPercentEncoding` 解码，且不影响防穿越。

### 测试方法（无头模式）
```bash
swift build
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"   # 应返回目录列表
```

---

## 6. 明确不做（v1 范围外，留给 v2）

- Apple 公证（要 $99/年开发者号）；https + 自签证书（仅当 html 用到 secure-context API 才需要）；跨网络隧道（cloudflared/ngrok/tailscale）；手机上传回电脑（双向）；菜单栏常驻形态。
- （自动更新已在 0.3 落地，见 §3「自动更新（Sparkle）」。）
