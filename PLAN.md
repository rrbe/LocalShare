# LocalShare · 设计与实现计划（PLAN）

> 一个 macOS 原生单窗口 app：不懂技术的同事打开它、选一个文件夹，窗口中央出现二维码，
> 用 iPhone 扫一下就能在 Safari 里浏览/打开那个文件夹里的 html 等文件。
> 全程不碰终端、不装 Homebrew、不依赖任何动态库。

本文件是**可移植的交接文档**——跟随 git 走，任何机器 `git pull` 后都能据此继续。

---

## 0. 背景与核心戒律

- 起因：要让小白同事在手机上看电脑里的 html。iOS Safari 不能直接开本地文件，AirDrop 过去也打不开，必须有一个**本机进程监听端口**对外提供 HTTP。
- 纯浏览器技术栈做不到（无法 listen 端口 / 接受入站连接），所以必须是原生 app。
- **核心戒律**：dufs 的崩溃根因是 arm64 二进制**运行时缺失动态库**（动态链接了 Homebrew 的 `liblzma.5.dylib`）。因此最终产物必须**零外部动态依赖**——只链接系统框架 + 第三方库以源码形式静态编进 app。Swift/SwiftUI + SPM 源码依赖天然满足。

---

## 1. 已锁定的设计决策

| 维度 | 决策 |
|---|---|
| 平台 | 仅 macOS（Apple Silicon 为主），原生 `.app` |
| 网络 | 仅同一 WiFi（LAN），无隧道/无公网/无账号 |
| 技术栈 | Swift / SwiftUI，只链接系统框架，零 dylib 风险 |
| HTTP 服务 | Swifter（SPM 源码编译进 app），只读静态服务 |
| 服务模型 | 选一个文件夹 → 移动端友好目录列表；目录含 `index.html` 则直接显示它；**防目录穿越**，所有路径锁死在所选文件夹内 |
| 鉴权 | 每次 app 启动生成随机 token，内嵌进二维码 URL（`?t=…`）；首访校验后种 cookie，后续资源自动放行；猜 `IP:端口` 的路人被 403 |
| 协议 | 明文 http（纯静态内容，无需 https/证书） |
| 二维码地址 | 裸 LAN IP（智能选接口、多候选给下拉）；窗口另显 `.local` 备选链接 + 可复制 URL |
| 二维码生成 | CoreImage `CIQRCodeGenerator`，无第三方库 |
| GUI | 单窗口：大二维码居中 + 可点/复制 URL + 当前文件夹/更换 + 启停状态 + 接口下拉 + “打不开?”排错行 |
| 生命周期 | 记住上次文件夹 · 开 app 自动起服务 · 端口自动选（占用则换）· 退出停服务 |
| 容错 | 检测无 WiFi/无 IP 并提示 · 首启引导点防火墙“允许” · 常驻排错提示 · 空文件夹友好态 |
| 分发 | Xcode ad-hoc 签名 · 你首次帮同事过一次 Gatekeeper（放行被持久记住） |
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
    HeadlessServer.swift   # LS_HEADLESS=1 无界面模式（测试/自动化用）
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
- `@main enum EntryPoint`：`LS_HEADLESS=1` 时走 `HeadlessServer.run()`（无界面，测试/自动化），否则 `LocalShareApp.main()` 跑 SwiftUI。
- `AppDelegate`（`NSApplicationDelegateAdaptor`）：`applicationDidFinishLaunching` 里 `NSApp.setActivationPolicy(.regular)` + `activate(ignoringOtherApps:)`（裸跑也能前台）；`applicationShouldTerminateAfterLastWindowClosed → true`（关窗即退出 → 停服务）。

### HeadlessServer（测试/自动化）
- `LS_HEADLESS=1` 时仅起 `FileServer` 并 `RunLoop.main.run()`，不拉 GUI。环境变量：`LS_FOLDER`（必填）、`LS_TOKEN`（默认 `testtoken`）、`LS_PORT`（默认 8080）；启动后打印 `LS_URL …` 便于脚本读取。

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

- Apple 公证（要 $99/年开发者号）；https + 自签证书（仅当 html 用到 secure-context API 才需要）；跨网络隧道（cloudflared/ngrok/tailscale）；手机上传回电脑（双向）；自动更新；菜单栏常驻形态。
