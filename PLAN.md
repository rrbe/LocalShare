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
| 鉴权 | 每次「分享」动作生成随机 token（0.7 起；换分享/停止即轮换，旧链接、旧 cookie、拍走的旧二维码即刻作废，权限不跨分享延续），内嵌进二维码 URL（`?t=…`）；首访校验后种会话 cookie，后续资源自动放行；猜 `IP:端口` 的路人被 403 |
| 协议 | 明文 http。威胁模型：防「猜地址的路人」（52 bit token），不防同网嗅探与持链者转发——后者的风险窗口随 token 轮换收敛到单次分享内。自签证书会把扫码进门变成手机上的证书警告页，伤害核心体验，不做（0.6 加入上传后内容不再纯静态，重新评估过，结论不变） |
| 二维码地址 | 裸 LAN IP（智能选接口、多候选给下拉）；窗口另显 `.local` 备选链接 + 可复制 URL |
| 二维码生成 | CoreImage `CIQRCodeGenerator`，无第三方库 |
| GUI | 单窗口：大二维码居中 + 可点/复制 URL + 当前文件夹/更换 + 启停状态 + 接口下拉 + “打不开?”排错行 |
| 生命周期 | 记住上次文件夹 · 开 app 自动起服务 · 端口自动选（占用则换）· 退出停服务 |
| 容错 | 检测无 WiFi/无 IP 并提示 · 首启引导点防火墙“允许” · 常驻排错提示 · 空文件夹友好态 |
| 分发 | Xcode ad-hoc 签名 · 你首次帮同事过一次 Gatekeeper（放行被持久记住） |
| 自动更新 | Sparkle（二进制 framework，`@rpath` 内置进 `Contents/Frameworks/`）· 自动后台检查、发现新版弹提示由用户确认 · 信任链走 **EdDSA 签名**（与 ad-hoc 代码签名无关，故未公证也安全）· appcast 作为 GitHub Release 资产上传，feed 走 `releases/latest/download/appcast.xml` 固定地址，**发布对仓库零写入**（仓库根 `appcast.xml` 已于 0.7.0 冻结，仅供老客户端迁移） |
| 沙盒 | **不开 App Sandbox**（内部手发、不上 App Store），省掉沙盒对“读任意文件夹”的限制 |
| 国际化 | 简体中文 + English 双语（0.9）。文案编进二进制（`Lang.swift`，不依赖资源 bundle，同 MarkedJS 思路）；**两个解析域彼此独立**——原生 app 跟设置（跟随系统 / 中文 / English），网页**逐请求**按浏览器 `Accept-Language` 协商、绝不读 app 设置。加语言只需在 `L`/`LStr` 各补一支 |

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
    Lang.swift             # i18n：编进二进制的中英文案表（L/LStr/i18nJSON）；app 跟设置、网页跟 Accept-Language
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
1. **鉴权**：读 `?t=`，或读 cookie `ls_token`。任一等于当前分享的 token 即放行（每请求取一次快照，轮换瞬间不串）；都没有 → 返回 403 小页面。若靠 `?t=` 放行，则在响应里加 `Set-Cookie: ls_token=<token>; Path=/; SameSite=Lax; HttpOnly`（会话 cookie，不设 Max-Age——token 轮换后旧值反正立即失效；页面 JS 不读它）。
2. **路径安全**（先解码，再防穿越）：
   ```
   decoded = request.path.removingPercentEncoding   // 修正上面的 Swifter 编码残留
   rel     = decoded 去掉前导 '/'
   root    = folderURL.resolvingSymlinksInPath().standardizedFileURL.path
   target  = root.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath().path
   guard target == root || target.hasPrefix(root + "/") else { 403 }
   ```
   `standardizedFileURL` 解掉 `..`，杜绝 `GET /../../etc/passwd`；编码点点（`%2e%2e`）也因「先解码后标准化」被一并挡住。
3. **目录**：① 若请求的目录路径不以 `/` 结尾 → 先 301 加斜杠（让 `index.html` 里的相对资源能正确解析）；② 含 `index.html` → 发该文件；③ 否则发 DirectoryListing 列表页。列表 href 为**绝对路径并逐段百分号编码**（`encodePath`，保留 `/` 分隔符）；隐藏文件（`.` 开头）不列。非根列表首行固定「返回上一级」（不参与前端筛选/排序，空目录也保留，多选子树的上一级天然指回虚拟根）；文件行 `target=_blank` 新标签打开、目录行原地进入。
4. **文件**：按扩展名查 MIME（text 类加 `; charset=utf-8`，关键——中文 html 才不乱码），`FileHandle` 分块（64KB）`writer.write(Data)` 流式发。例外：`.md(.markdown)`/`.json(.geojson)`/`.csv(.tsv)` 的**浏览器导航**（Accept 含 `text/html` 且无 `?raw=1`）发预览壳页（共用 `PreviewPage` 骨架：`MarkdownViewer` 内嵌 vendored marked、原始 HTML 转义不执行；`JsonViewer` 手写折叠树 + 路径搜索；`CsvViewer` 手写 RFC4180 解析 + 排序/筛选，后两者零 vendored 依赖；大数据靠懒构建/分档渲染兜底）；壳页与文件同 URL，正文相对引用（`assets/` 图、相邻 md 链接）由浏览器解析、命中本表的常规服务，多选虚拟根因 key=lastPathComponent 保持原名而同样成立。curl/脚本/壳页取文（Accept `*/*`）与 `?raw=1` 一律拿原始文件（页角「查看原文」）。

> 单文件夹的 2~4 步抽成 `serveTree(rootURL:relPath:…)` 复用。**单文件**直接发那一个文件。**多选**（`Share.multiple([Item])`，`Item` 持 `key`/`url`/`isDir`，`makeItems` 由选中 URL 构造、key 取 lastPathComponent 并对极少数重名做 `-2` 后缀兜底）：空路径 → 合成虚拟根列表页（`DirectoryListing.html(items:rootName:)`，rootName=「分享内容」）；否则拆首段 `key` 查项——文件项仅当无子路径才发、目录项以 `item.url` 为根走 `serveTree`（`relPath`=去掉 key 段后的剩余，面包屑天然渲染成「分享内容 / key / …」）。未知 key / 文件项带子路径 → 404；穿越判据每项独立。Headless 测多选用 `LS_FOLDERS`（`:`/换行分隔）。

> **网页侧 XSS 硬化（0.7.x）**：被服务的内容跑在分享源（`http://本机:端口`）下，HTML/SVG 会被当同源页面执行脚本——能在浏览者会话里读写整个分享、把页面伪装成可信的列表页钓鱼、拿浏览者当 LAN 跳板。两道防线：
> 1. **访客上传去势（主修）**：`sanitizeFileName` 末尾对 `executableDocExtensions`（html/htm/xhtml/xht/shtml/svg/svgz/mht/mhtml）追加 `.txt`，落地成 `text/plain`。专堵「传一个 `index.html` 顶替目录列表页 → 别人点进该目录**零点击**执行脚本」这条存储型 XSS（`availableURL` 只在重名时改名，故空目录里的 `index.html` 会成为默认页），也中和点开即跑的上传 HTML/SVG。文件本体保留、不丢。
> 2. **全站 `X-Content-Type-Options: nosniff`（纵深防御）**：关掉浏览器 MIME 猜测。正确声明类型的文件照常内联显示、未知类型本就 `octet-stream` 下载，**零回归**；它拦的是「octet-stream 被猜成 HTML 执行」，拦不住「类型本就是 text/html 的执行」——所以 defang 才是上传向量的主修，nosniff 是补强。
> 3. **Markdown 链接/图片协议白名单**：`.md` 走 marked 预览渲染、不经上面的去势，故单独在 `MarkdownViewer.rendererConfig` 覆盖 marked 的 `link`/`image` 渲染器——只**放行**安全协议（链接 `http`/`https`/`mailto`/`tel`，图片再加 `data:`）与相对/锚点，其余一律拦，堵「恶意 `.md` 里一个 `[x](javascript:…)` 链接被点开即在分享页同源跑脚本」；用白名单而非黑名单，因黑名单天然漏（实体编码、未来新协议）。两个易错点：**(a) 先解 HTML 实体再判**——marked 默认渲染器把 href 里的实体（`&#106;avascript:`、`javascript&colon;`）原样写进属性、浏览器解析时才解码，不解码就「检查串≠执行串」被旁路；**(b)** 解码后再剥掉码点 ≤32 的字符（挡 `java<TAB>script:`），冒号须在任何 `/ ? #` 之前才算协议。安全 URL 返回 `false` 走 marked 默认渲染，不误伤。配置用 `/* MD-RENDERER-CONFIG */` 标记，`tools/smoke-md-link-sanitize.cjs` 连同**真实 vendored marked** 在 node 里跑断言（含实体编码绕过用例，测真配置非复刻）。
>
> **只作用于上传/不可信内容路径**：分享者自己放进文件夹的静态站点（含磁盘上的 `index.html`）经 `.directory` 直接服务、不过 `sanitizeFileName`，照常渲染——「分享一个站点目录、index.html 当首页」的功能不受影响。回归测试 `tools/smoke-upload-defang.sh`（无头 + curl，复现完整攻击链 + 不误伤正常文件 + 不破坏磁盘静态站点）。
>
> **配套两项卫生加固（0.7.x）**：① **token-302 清洗**——浏览器经 `?t=` 首访（Accept 含 `text/html`、尚无 cookie）时，种好 cookie 后立刻 302 到去掉 `?t=` 的同一路径，token 不残留地址栏/历史；curl/脚本与壳页 `?raw=1`/子资源（Accept `*/*`）不触发、照旧直接拿内容（测 `tools/smoke-token-302.sh`）。② **上传文件打 `com.apple.quarantine`**——访客上传落地后 `setxattr` 隔离属性，分享者双击时与「浏览器下载的文件」同享 Gatekeeper 待遇（纯 libSystem，best-effort）。
>
> 未做（接收端是浏览器、自签 TLS 会触发证书警告页伤体验，与「扫码即用」冲突，业界同形态产品如 LocalSend 的 Web Share 同样退回明文 HTTP）：传输层加密。明文 HTTP 下「同网嗅探/恶意 AP 读到 `?t=` 或文件流」是该形态的固有上限，靠 token 轮换 + 默认只读 + 二维码带外传 token 收敛，详见威胁模型行。

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
- 分享变更：不重启 server（端口不变），加锁更新 FileServer 的 share 与 token——先换钥匙再换内容，杜绝旧 token 瞬间可读新分享。
- token 每次「分享」动作生成（QR 与校验共用）：`setShared` 与 `stop` 均轮换，旧链接/cookie/二维码即刻作废；在线感知记录随轮换清零。窗口里的地址条显示与复制同一字符串（完整 URL 含 `?t=`，超长仅 UI 中段省略），无「隐 token 的展示地址」。

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
- **CI 链路**（`.github/workflows/release.yml`）：build → 依赖闸门 → 打 DMG → 建 Release → 用 `sign_update` 对 DMG 做 EdDSA 签名 → 生成单条 `<item>` 的 `appcast.xml`（enclosure 指向 Release 里的 DMG URL）→ **作为资产上传到本次 Release（不提交 git，发布对仓库零写入）**。feed 即 `https://github.com/rrbe/LocalShare/releases/latest/download/appcast.xml`（GitHub 恒指向最新 release 的同名资产）。一次性迁移随 v0.7.0 完成：仓库根 `appcast.xml` 已冻结在 0.7.0、仅服务 ≤0.6.0 老客户端（feed 指向旧 raw master），升级后即转入新 feed；详见 CLAUDE.md「发布与版本」。

#### 一次性配置（EdDSA 密钥）— ✅ 已完成，下列为留档
当年生成密钥对的步骤（仅作记录，无需重做）：
1. 本地装 Sparkle 工具后生成 EdDSA 密钥对：`./bin/generate_keys`（私钥进登录钥匙串，终端打印 base64 **公钥**）。
2. 公钥已填入 `bundle/Info.plist` 的 `SUPublicEDKey`（当前值 `yF0fhsSuotJutGHezmoAFb3+M7nA6gcOln5aEWycXp8=`，**非占位**）。公钥非机密，直接进仓库。
3. 私钥已存为 GitHub 仓库 secret **`SPARKLE_ED_PRIVATE_KEY`**（导出用 `./bin/generate_keys -x private_key.pem`）。**私钥绝不入仓库**。
   - 兜底逻辑仍在：未配 secret 时 CI 跳过 appcast 生成（仅出 DMG，发 `::warning::`）；`Info.plist` 仍是占位公钥时 app 不启动 updater。两道保险让「未配置」状态显式可见。

### 容错 UI
- 无 WiFi / 无私网 IP → 不画死码，显示“请先连接 WiFi”。
- 首次 start 触发 macOS 防火墙“是否允许接受传入连接”——UI 文案引导点**允许**（误点拒绝是现实中“扫了码却打不开”头号原因）。
- 二维码下常驻一行：“打不开？→ 确认两台设备在同一 WiFi，且该 WiFi 未开启‘访客/设备隔离’。”

### 国际化（i18n，0.9）
- **形态**：简体中文（基准）+ English 双语，全部用户可见文案做成**编进二进制的 Swift 字符串表**（`Lang.swift`），不依赖任何资源 bundle——与 `MarkedJS.source`、`permSummary` 同一思路，三条启动路径（GUI / CLI / headless）都无须定位文件，升级整文件替换。
- **两个解析域彼此独立**：① 原生 app 语言来自设置（`AppState.langPref`：跟随系统 / 中文 / English，持久化），`Lang.current` 是给拿不到 `AppState` 的菜单/命令构造处（`App.swift` / `Updater.swift`）读的静态快照，由 `AppState.init` / `setLangPref` 同步；② 网页**逐请求**由浏览器 `Accept-Language` 决定（`Lang.fromAcceptLanguage`：按 `q` 值降序、同 q 保留先出现者、`q=0` 即「明确不接受该语言」跳过），**绝不读 app 设置**——同一台 Mac 分享，电脑界面可中文而手机按自己的系统语言显示。
- **文案分三类**：静态文案走 `L`（`CaseIterable` 枚举键，`switch` 返回 `(zh, en)`，编译器强制穷尽、无 Optional / 强解包，新增即加一个 case）；带插值 / 复数 / 中英语序差异的走 `LStr`（按 `lang` 分支拼装）；网页里由 JS 在浏览器侧拼接的走 `LStr.i18nJSON`（注入一个带 `{占位符}` 的字典，JS 只做 replace，语序逻辑仍留在 Swift 侧；`DirectoryListing` / `PreviewPage` 两个生成页都 emit `<script>var LS_I18N=…</script>`）。
- **安全**：`i18nJSON` 的值注入 `<script>` 内联块，`jsEscape` 除转义 `\` / `"` / 换行外还把 `<` 转成 `\u003c`，挡 `</script>` 提前收尾（与全站 XSS 硬化同一精神）。
- 测试：`Tests/LocalShareTests/LangTests.swift`（`Accept-Language` 协商、`q` 值优先级、`L` 穷尽性）+ `tools/smoke-accept-language.sh`（无头 + curl 验网页逐请求语言切换），均已挂进 CI。

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
- [x] 自动更新（Sparkle）：framework `@rpath` 内置进 `Contents/Frameworks/` + 深度签名；放宽后依赖闸门（build.sh/CI）只许内置 framework；`Updater.swift` + Info.plist 配置；CI 走 EdDSA 签名 + appcast 作为 Release 资产上传（feed `releases/latest/download`，零写仓库）。EdDSA 密钥已一次性配置完成（见 §3）。
- [x] 命令行启动：`localshare <路径>…` 转发 GUI / `--headless` 前台模式 / 设置面板安装 symlink；
      已验证 symlink 经 dyld realpath 加载包内 Sparkle、冷启动 open 事件缓冲、热切换实例复用、
      终端二维码 Vision 实扫解码通过；release 编译器坑已规避并注释（见 §3「命令行启动」）。
- [x] 在线感知「N 人正在浏览」：FileServer 按客户端 IP 记 lastSeen（45s 窗口，复用 share 同一把
      NSLock），listing 页 JS 每 15s 打 `/ls/ping`（保留路径，先于分享内容命中）回 `{"viewers":n}`；
      GUI 由 AppState 2s 轮询展示（0 人隐藏），网页端 ≥2 人才显示（自己即 1 人）。
      已知缺口：用户自带 index.html 无法注入心跳，只能靠请求时间近似。
      已验证：双 IP 计 2、同 IP 多请求计 1、无 token 403、中文名/防穿越无回归、release 冒烟通过。
- [x] 访客上传 v1（0.6）：`Permission.add` 接真后端 —— 设置页开关（仅单文件夹分享可开，换分享
      自动回只读）；listing 页上传按钮 + 整页拖拽 + XHR 进度条，完成后刷新；POST multipart 到当前
      浏览目录（落点过同一套防穿越校验），文件名只取末段并清洗（拒空名/点开头，":" 换 "-"），
      重名 -2 兜底，itemReplacementDirectory 临时文件 + 原子 moveItem；500MB 上限（前端先拦、
      服务端 413 兜底——注意 Swifter 进 middleware 前已把 body 整段读进内存，上限只能事后拒绝，
      流式/分片是 v1.5 的事）；GUI「新收到」卡片点击 Reveal in Finder；headless 用 `LS_UPLOAD=1`。
      网页措辞（kicker/colophon）经 permSummary 派生，开上传自动变「可读写分享」。
      已验证：根/子目录上传、文件名穿越清洗、目标路径穿越 403、重名 -2、中文/空格名、点开头 400、
      不存在目录 404、无 token 403、开关关 403、多选/单文件分享 403、501MB 413 且不落盘、
      上传内容逐字节完整、未开上传时页面无按钮且措辞仍「只读」、release 冒烟全过。
- [x] 在线访客显示设备名（0.7.x，PR #15）：`FileServer` 后台 best-effort 反查访客 IP 的设备名
      （`getnameinfo`+`NI_NAMEREQD`，串行队列、同 `NSLock` 缓存于 `nameCache`、对端自报名清洗去
      控制/RTL 码点、随 token 轮换清零），GUI 单台直呼其名、多台「… 等 N 人」、查不到回退「…尾号」；
      **网页 `/ls/ping` 仍只回人数**。已知现实：iPhone 多经 mDNS 注册、普通 PTR 常查不到。
- [x] 「仅当前网络可见」开关（0.7.x，PR #15）：`AppState.bindSelectedOnly` → `FileServer.listenAddress`，
      开启则只绑选中网卡的私网 IPv4（Swifter 原生 `listenAddressIPv4`，无须 fork），默认仍绑 `0.0.0.0`；
      切网卡/切开关不轮换 token 地重绑、绑定 IP 消失自动回退全接口并提示；非法地址经 `inet_pton` 校验
      抛错而非静默绑全接口。冒烟 `tools/smoke-bind-interface.sh`。
- [x] 明文风险提示（0.7.x，PR #15）：底部「连不上?」气泡 + 设置·访问权限 区各一行克制灰字，告知公共
      Wi-Fi 下传输不加密、同网可能被嗅探（与 §1 威胁模型一致；自签 TLS 仍不做）。
- [x] 国际化 i18n（0.9，PR #22）：简体中文 + English 双语，文案编进二进制（`Lang.swift`，不依赖资源
      bundle，三条启动路径都无须定位文件）。两个解析域独立——原生 app 跟设置（跟随系统 / 中文 / English，
      `AppState.langPref`，设置页加「语言」分段），网页**逐请求**按浏览器 `Accept-Language` 协商（`q` 值
      降序、`q=0` 跳过），绝不读 app 设置。文案分 `L`（静态，编译器强制穷尽）/ `LStr`（插值 / 复数 / 语序）
      / `LStr.i18nJSON`（JS 侧拼接，`jsEscape` 防 `</script>`）。详见 §3「国际化（i18n）」。
      已验证：`LangTests` 单测（协商 / q 值 / 穷尽）+ `tools/smoke-accept-language.sh` 冒烟，CI 全过；
      release 编译通过。
- [x] 传递文本 v1 — Mac→手机发文本（PR #25）：`AppState.sharedText` 与 share 正交，保留路径 `/ls/text`
      提供（导航发 `TextViewer` 壳页、`?raw=1`/curl 发 `text/plain` 原文），可独立分享或挂进多选虚拟根的
      文本行；离散提交快照、点「分享/更新」即轮换 token；空态加「分享文本」入口（自带 `NSTextView`、
      placeholder 由其自绘以兼容中文输入法组合态）；手机页纯文本 + 大「复制」按钮（`execCommand` 回退——
      纯 http LAN 是非安全上下文、`navigator.clipboard` 不可用）+ http(s) 安全自动链接；设置「记住分享的
      文本」默认关（开则重启回填草稿、**不自动广播**）；历史复用 `RecentShare`（扩 `text:`）+ 逐条 ✕ 删除 +
      「清空」二次确认。`textContent` 注入 + `<`→`<`（共享 `LStr.jsEscape`）双重防注入；`LS_TEXT`
      headless 钩子；`tools/smoke-text.sh`（15 项）+ `TextShareTests` 入 CI。设计见 §7「传递文本」。
- [ ] 传递文本 v2 — 手机→Mac 收文本（实现中）：见 §7「传递文本 · v2」。

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

- Apple 公证（要 $99/年开发者号）；https + 自签证书（仅当 html 用到 secure-context API 才需要）；跨网络隧道（cloudflared/ngrok/tailscale）；菜单栏常驻形态。
- （自动更新已在 0.3 落地，见 §3「自动更新（Sparkle）」；手机上传回电脑已在 0.6 落地，见 §5 进度。）

---

## 7. 规划中（v0.7+）

（访客上传 v1 已在 0.6 落地，见 §5 进度；当年切范围的理由：上传解决手机照片/文档传到 Mac
这 90% 的诉求，在线编辑在手机浏览器体验差、覆盖丢数据风险大，删除误删风险高，均往后放。）

### 传递文本（v1 已落地，v2 实现中）

让「选内容→手机扫码」的内容从「磁盘文件」扩到「一段文本」——剪贴板/链接/口令/说明从桌面甩到手机，
以及反向把手机上的文本收回电脑。**两条独立单向通道，不是同步便签**：发出去的 `sharedText` 与收回来的
收件箱互不喂给对方。分两个版本交付，因为两端在现有架构里的「落点」完全不对称：

- **发出去（Mac→手机）几乎全复用现有只读管线**——整个 app 本就是「把内容喂给手机看」，文本只是又一种被
  GET 的内容，唯一新东西是「内容源是内存里的 `String` 而非磁盘 `URL`」。低风险、高杠杆，先做。
- **收回来（手机→Mac）的难点不在传输**（一个表单 POST 比现有 multipart 上传还轻），而在于 **Mac 要长出
  一个「收件箱」形态**：新原生 UI + 新生命周期（收到的文本往哪放/怎么清）+ push 模型。独立成 v2。

#### v1 — Mac → 手机·发文本（已落地，PR #25；落点见 §5 进度）

| 维度 | 决定 |
|---|---|
| 数据模型 | `AppState` 加 `sharedText: String?`（全局单一文本，一次只一段） |
| 与文件关系 | 混进多选**虚拟根**当一个条目；**也能独立分享**（一个文件都不选——这才是「传文本」的主力场景） |
| 「空」判定 | 从 `sharedItems.isEmpty` 改为 `sharedItems.isEmpty && sharedText == nil`，牵动 `start/stop/恢复/QR` 全链 |
| 交互模型 | **离散提交快照**：输入框打字不广播，点「分享」才把当前文本快照发出去 = 一次 `setShared` → **轮换 token**；要改就改完再点「更新分享」（再轮换）。与「一次分享=一次 setShared=换钥匙」完全一致，不存在边打字边失效 |
| 路由 | 仅文本无文件 → 扫码直达文本页（同「单文件直接发那一个」）；文本+任意文件 → 落虚拟根列表，文本是其中一条。文本服务在保留命名空间 `/ls/text`（像 `/ls/ping` 一样**先于**虚拟根 key 匹配），躲开「有文件正好叫 text」的 key 撞车 |
| 持久化 | 设置项「持久化分享文本」**默认关**。关 → 文本压根不写进 recents/UserDefaults；开 → 记一条可恢复（但**不自动 start**）的 history。理由：文本常是密码/验证码/一次性口令，自动恢复+自动起服务会在 LAN 上悄悄重新暴露上次那段 |
| 历史 | 复用现成 `.history` 屏 + `RecentShare`（扩 `text: String?`，无 path 的文本条目）。顺手把**「逐条删除」做成 history 通用能力**（文件条目也能删——路径同样泄信息）。删 history ≠ 停掉当前直播的 live 分享 |
| 原生入口 | 空态「文件 / 文本」**双平级入口**：文件那块旁并列「分享文本」，切到 TextEditor + 「分享」；分享进行中可再调出同一文本框追加 |
| 手机页 | 纯文本转义显示 + 大「复制」按钮 + http(s) URL 安全自动链接（沿用 `MarkdownViewer` 协议白名单挡 `javascript:`）。**不当 Markdown 渲染**（任意纯文本里的 `* _ #` 会被吃掉） |
| 取原文 | `?raw=1` / curl（Accept `*/*`）拿 `text/plain; charset=utf-8` 原文，导航（`text/html`）给壳页——同 md/json/csv 预览的同 URL 双形态 |
| 大小 | **不设上限**：文本是 Mac 端自己粘的、非不可信输入，不必像上传那套；空白文本禁用「分享」按钮 |

#### v2 — 手机 → Mac·收文本（实现中）

| 维度 | 决定 |
|---|---|
| 本质 | **独立收件箱通道**，不落盘、不依赖文件夹分享，与 v1 对称（都在 app 里以文本形态存在） |
| 收件箱 | 列表，每条带时间 + 来源（复用现成 `nameCache`/`getnameinfo` 反查设备名，查不到显 IP），单条复制/删除/清空 |
| 持久化 | 设置项「持久化收到的文本」**默认关**（对称 v1；收到的常更敏感/更像垃圾，默认易逝更稳） |
| 闸门 | opt-in 默认关（参照 `uploadEnabled`），但**不限分享形态**——收文本不依赖落点，任意模式甚至「什么都没分享」都能开，开了就把服务拉起并出一张指向发送页的 QR |
| 提醒 | **仅应用内**：复用 `onUpload` 的「新收到」卡片机制（socket 线程 hop 回 MainActor）+ 收件箱未读角标。不发系统通知（macOS 通知要授权，且未公证 ad-hoc 签名下可靠性存疑，往后放） |
| 防滥用 | **双上限**：单条文本 ~64KB（远小于上传 500MB）+ 收件箱 ~100 条满了挤掉最旧。不做速率限制（Swifter 不便做、opt-in+LAN 信任足够）。**必须双限**：Swifter 进 middleware 前已把整段 body 读进内存，光限单条挡不住「刷一堆刚好不超限的消息撑爆内存」 |
| 手机端 | 「发文本给电脑」textarea + 发送，放在 listing 页（及独立收文本页）**与现有上传表单同处、同样的出现条件**（收件箱关时不出现） |

#### 贯穿约束（实现时必须守）

- **clipboard 在纯 http LAN 下不可用**：`navigator.clipboard.writeText` 只在 secure context（https / localhost）可用，
  而本服务是 `http://192.168.x.x`，复制按钮必须回退到 `document.execCommand('copy')` + 选中隐藏 textarea，
  否则「点了没反应」。这与「不做 TLS」的威胁模型直接相关。
- **Swifter body 预读内存**：上限只能事后拒绝（同上传），故 v2 必须单条+总数双限。
- **token / 302 去 `?t=` / 网卡绑定 / i18n（`L`/`LStr`，文案过表）/ 转义** 全自动沿用现有机制；收到的文本在
  SwiftUI `Text` 里显示天然不执行，但若回显进任何**服务页**须转义。
- v1/v2 各自一个持久化开关（实现时定为**各一个**：v1「记住分享的文本」已落地、v2「持久化收到的文本」
  待加；两者隐私语义不同——发出去的是自己粘的、收回来的是他人投递的，分开开关更清晰）。

### 上传 v1.5：分片上传

绕开 Swifter「整段 body 进内存」的根本限制：前端把大文件切片（每片 16–32MB）逐片 POST，
服务端按序 append 到临时文件、末片原子换名。任意大小可传、内存恒定，还顺带断点续传的底子。
不 fork Swifter。落地后可放开（或大幅提高）500MB 上限。

### 写权限后续

- `Permission.edit` / `Permission.del`（在线编辑、删除）：后端未实现，开关已留好；做之前先想清
  覆盖丢数据与并发冲突的兜底。

### 设备名反查后续

- 现为 best-effort `getnameinfo`（已落地，见 §5），iPhone 多查不到、回退 IP 尾号。要更准需走
  `DNSServiceQueryRecord` 的 mDNS PTR 查询，成本高且仍不保证命中，暂不做。

> v0.7.x 已落地的小项（设备名反查、「仅当前网络可见」、明文提示）已移入 §5 进度，不再列为规划。
