import Foundation
import Darwin   // getnameinfo / inet_pton / sockaddr_in（设备名反查）
import Swifter

// 基于 Swifter 的只读静态文件服务。
// 全部逻辑放进单个 middleware 闭包（永远返回 response），绕开 router。
// 安全：① token 鉴权（query 或 cookie）；② 防目录穿越（路径解析后必须仍在所选文件夹内）。
final class FileServer {
    // 分享对象：整个文件夹、单个文件（扫码直接打开它，不暴露同目录其它文件），
    // 或多个文件/目录（合成一个虚拟根列出这批项目，首段路径映射到对应真实 URL）。
    enum Share {
        case directory(URL)
        case file(URL)
        case multiple([Item])

        // 多选模式下的一个被选项目：key 是它在虚拟根下占用的 URL 路径段。
        struct Item {
            let key: String
            let url: URL
            let isDir: Bool
        }

        // 由选中的 URL 列表构造有序项；key 取 lastPathComponent。多选通常同源一个父目录、兄弟项本不重名；
        // 仅对「跨目录拖拽」这类边角追加 -2/-3 后缀兜底，避免两项映射到同一 key 造成路由二义。
        static func makeItems(_ urls: [URL]) -> [Item] {
            let fm = FileManager.default
            var used = Set<String>()
            var items: [Item] = []
            for url in urls {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
                let base = url.lastPathComponent
                var key = base
                if used.contains(key) {
                    let ext = (base as NSString).pathExtension
                    let stem = (base as NSString).deletingPathExtension
                    var n = 2
                    repeat {
                        key = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
                        n += 1
                    } while used.contains(key)
                }
                used.insert(key)
                items.append(Item(key: key, url: url, isDir: isDir.boolValue))
            }
            return items
        }
    }

    // 多选虚拟根的显示名（列表页 H1 / 面包屑根）。多选无共同磁盘根，故给个中性名。仅网页用，按请求语言。
    static func multipleRootName(_ lang: Lang) -> String { lang == .zh ? "分享内容" : "Shared items" }

    private let server = HttpServer()

    // 监听地址：nil = 绑定全部接口（0.0.0.0，默认）——回环可达、对网络切换鲁棒，headless/CLI 与冒烟
    // 测试都走这条。设为某块网卡的私网 IPv4 时，socket 只绑那一个地址，分享便仅在该网络可见
    // （GUI「仅当前网络可见」开关，opt-in）。Swifter 原生支持，无须 fork（见 start）。
    var listenAddress: String?

    // share 与 token 都可能在运行中被“更换”修改，故加锁；请求处理在后台 socket 线程读取。
    private let lock = NSLock()
    private var _share: Share
    var share: Share {
        get { lock.lock(); defer { lock.unlock() }; return _share }
        set { lock.lock(); _share = newValue; lock.unlock() }
    }

    // 访问令牌随每次「分享」动作轮换（AppState 负责生成）：旧 ?t= 链接与旧 cookie 即刻失效，
    // 不重启 server、端口不变。换钥匙=换观众，在线记录一并清零（旧访客的下一次心跳将被 403）。
    private var _token: String
    var token: String {
        get { lock.lock(); defer { lock.unlock() }; return _token }
        set { lock.lock(); _token = newValue; lastSeen = [:]; firstSeen = [:]; nameCache = [:]; nameLookupInFlight = []; lock.unlock() }
    }

    // MARK: - 访客上传（Permission.add，v1 仅单文件夹分享）
    // 开关可在运行中切换（设置页），与 share 同款加锁。落点 = 访客当前浏览的目录。
    private var _uploadEnabled = false
    var uploadEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _uploadEnabled }
        set { lock.lock(); _uploadEnabled = newValue; lock.unlock() }
    }
    // 每存好一个文件回调一次（socket 线程）；GUI 用它提示「新收到」，设置方自行 hop 主线程。
    var onUpload: ((URL) -> Void)?

    // MARK: - 收文本（手机→Mac，v2）
    // 与 share 正交的独立收件箱通道：开关开启时 POST /ls/text 收一段文本、GET /ls/send 出发送页。
    // 不落盘、不依赖文件夹分享（任意分享形态甚至「什么都没分享」都能开）。同 uploadEnabled 加锁、运行中可切。
    private var _textInboxEnabled = false
    var textInboxEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _textInboxEnabled }
        set { lock.lock(); _textInboxEnabled = newValue; lock.unlock() }
    }
    // 每收到一段文本回调一次（socket 线程）；GUI 用它入收件箱 + 提示未读，设置方自行 hop 主线程。
    var onReceiveText: ((ReceivedText) -> Void)?

    // Remote mode is deliberately a server-wide read-only gate: the same origin is
    // reachable on LAN and through the remote agent, so allowing POST locally would
    // also expose it remotely.
    private var _remoteAccessEnabled = false
    var remoteAccessEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _remoteAccessEnabled }
        set { lock.lock(); _remoteAccessEnabled = newValue; lock.unlock() }
    }
    // 单条文本上限（远小于上传的 500MB）。Swifter 进 middleware 前已把 body 整段读进内存，故同上传只能
    // 事后拒绝；总数上限（收件箱满挤旧）由 AppState 把关——两道一起才挡得住「刷一堆不超单条限的消息撑爆内存」。
    static let textInboxLimit = 64 * 1024

    // MARK: - 分享文本（Mac→手机，v1）
    // 与 share 正交的一段文本：非 nil 即在保留路径 /ls/text 提供（导航发预览壳页、?raw=1/curl 发原文）。
    // 纯文本分享时 share=.multiple([])（虚拟根无文件项），二维码直指 /ls/text；与文件共存时挂进虚拟根
    // 列表。内容随每次「分享/更新」动作由 AppState 轮换 token 后写入，同 share 加锁、socket 线程读。
    private var _sharedText: String?
    var sharedText: String? {
        get { lock.lock(); defer { lock.unlock() }; return _sharedText }
        set { lock.lock(); _sharedText = newValue; lock.unlock() }
    }

    // 文本在虚拟根列表里的条目显示名：取首个非空行截断（约 60 字），整段纯空白回退由列表页兜底。
    // 用 .newlines 在 unicode 标量层切分——Swift 把 CRLF 视作单个 Character，按 Character 比较会漏掉 \r\n。
    static func textPreview(_ text: String) -> String {
        let firstNonBlank = text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        return String(firstNonBlank.trimmingCharacters(in: .whitespaces).prefix(60))
    }

    // Swifter 在进 middleware 前已把请求体整段读进内存（HttpParser.readBody），上限只能事后
    // 拒绝、省掉 multipart 的二次拷贝；前端先行拦截超限文件。流式/分片上传是 v1.5 的事。
    static let uploadLimit = 500 * 1024 * 1024

    // token-302 重建剩余 query 时用：从 urlQueryAllowed 去掉在 query 里有分隔含义的字符，
    // 免得某个参数值里的 & = + ? # ; 把 302 的 Location 拆出额外参数（保真，非安全问题）。
    private static let queryComponentAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&=+?#;")
        return s
    }()

    // MARK: - 在线感知
    // 「正在浏览」近似为：最近 presenceWindow 内有过任何请求的客户端 IP（页面心跳、点开文件、
    // 下载大文件都算）。局域网内一台设备一个 IP，无须 cookie 标识；同设备多 tab 算一个人。
    // 心跳由 DirectoryListing 页内嵌 JS 每 15s 打一次 /ls/ping；用户自带 index.html 无法注入
    // 心跳，只能靠请求时间近似（可接受的已知缺口）。
    private static let presenceWindow: TimeInterval = 45
    private var lastSeen: [String: Date] = [:]   // ip → 最近请求时间（同 lock 保护）
    private var firstSeen: [String: Date] = [:]  // ip → 本次会话首次出现时间（与 lastSeen 同生命周期）
    // 设备名反查缓存（同 lock）：ip → 友好设备名；空串=查过但无名（回退 IP 尾号）；缺键=尚未查。
    private var nameCache: [String: String] = [:]
    private var nameLookupInFlight: Set<String> = []   // 正在后台反查的 ip，去重避免重复发起

    private func touchPresence(_ ip: String?) {
        guard let ip, !ip.isEmpty else { return }
        lock.lock()
        let now = Date()
        lastSeen[ip] = now
        if firstSeen[ip] == nil { firstSeen[ip] = now }   // 首次出现即记开始时间，之后只更新 lastSeen
        // 首次见到该 IP 时后台反查一次设备名；命中即缓存，之后直接读。
        let needsLookup = nameCache[ip] == nil && !nameLookupInFlight.contains(ip)
        if needsLookup { nameLookupInFlight.insert(ip) }
        lock.unlock()
        if needsLookup {
            Self.reverseLookup(ip) { [weak self] name in
                guard let self else { return }
                self.lock.lock(); self.nameCache[ip] = name; self.nameLookupInFlight.remove(ip); self.lock.unlock()
            }
        }
    }

    // 裁剪窗口外的活跃记录，并同步淘汰其设备名缓存与开始时间——三者与 lastSeen 同生命周期，免得只增
    // 不减（否则仅在 token 轮换时清）。调用方已持 lock。
    private func pruneExpiredLocked() {
        let cutoff = Date().addingTimeInterval(-Self.presenceWindow)
        lastSeen = lastSeen.filter { $0.value > cutoff }
        firstSeen = firstSeen.filter { lastSeen[$0.key] != nil }
        nameCache = nameCache.filter { lastSeen[$0.key] != nil }
    }

    // 活跃访客数。网页 /ls/ping 只回这个数字（不外泄设备名给其他访客）。
    func activeViewers() -> Int {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return lastSeen.count
    }

    // GUI 用：活跃访客明细，按最近活跃排序（最近在前）。每项带完整 IP、反查到的设备名（查不到为空串）、
    // 以及本次会话开始时间（since）。摘要行与展开列表各取所需（见 ViewerInfo.fullLabel）。
    // 仅供分享者本机的窗口显示——网页端永远只看到人数（见 activeViewers）。
    func activeViewerInfos() -> [ViewerInfo] {
        lock.lock(); defer { lock.unlock() }
        pruneExpiredLocked()
        return lastSeen.sorted { $0.value > $1.value }.map { ip, _ in
            ViewerInfo(ip: ip, name: nameCache[ip] ?? "", since: firstSeen[ip] ?? Date())
        }
    }

    // 反查设备名（best-effort）。getnameinfo 走系统解析器：家用路由器常把客户端 DHCP 主机名登记进
    // 反向 DNS，故有时能拿到名字；iPhone 多只经 mDNS 注册、普通 PTR 常查不到 → 回 ""，由
    // 展示层回退完整 IP（摘要行则归入「N 人正在浏览」）。取首段去本地域后缀作友好显示。
    // 串行队列：NI_NAMEREQD 对无 PTR 的设备会阻塞到 DNS 超时；既然 best-effort、延迟无所谓，串行可
    // 避免多个陌生 IP 同时到达时派生一堆被阻塞的线程（nameLookupInFlight 已按 IP 去重）。
    private static let lookupQueue = DispatchQueue(label: "localshare.namelookup")
    private static func reverseLookup(_ ip: String, completion: @escaping (String) -> Void) {
        lookupQueue.async {
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { completion(""); return }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
            guard r == 0 else { completion(""); return }   // NI_NAMEREQD：无名即非 0
            let first = String(cString: host).split(separator: ".").first.map(String.init) ?? ""
            completion(Self.sanitizeDeviceName(first))
        }
    }

    // 设备名由 LAN 对端自报（DHCP/PTR），不可信：剔除控制字符与 RTL/隔离等格式码点——咖啡馆这类
    // 网络下对端可自命名塞 U+202E 之类做视觉欺骗。SwiftUI Text(String) 本不解释 markdown/HTML，
    // 故无注入，这里只是 host 自己屏幕上的观感加固；再限长兜底。
    private static func sanitizeDeviceName(_ raw: String) -> String {
        let bidi: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        let kept = raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !bidi.contains($0.value) }
        return String(String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespaces).prefix(40))
    }

    init(share: Share, token: String) {
        self._share = share
        self._token = token
        server.middleware.append { [weak self] req in
            self?.handle(req) ?? .internalServerError
        }
    }

    // 依次尝试偏好端口；都占用则随机高位端口。返回实际绑定端口，全失败抛错。
    @discardableResult
    func start(preferredPorts: [in_port_t]) throws -> in_port_t {
        // 监听地址若非合法 IPv4：Swifter 的 inet_pton 会静默失败、sin_addr 保持 0 即 INADDR_ANY——
        // 「仅当前网络可见」会无声地对所有网络开放，与承诺相反。提前抛错，把这条隐性失败显式化：
        // GUI 侧让上层「回退全接口并提示」的安全网接住（而非依赖 bind() 失败），headless 侧直接启动失败。
        // GUI 的地址恒来自 getifaddrs、本不会触发；这是给 LS_BIND / 日后误用的兜底。
        if let addr = listenAddress {
            var probe = in_addr()
            guard inet_pton(AF_INET, addr, &probe) == 1 else {
                throw NSError(domain: "FileServer", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: LStr.invalidBindAddress(addr, Lang.systemDefault)])
            }
        }
        // nil → INADDR_ANY（全接口）；非 nil → 只绑该 IPv4。forceIPv4 取 listenAddressIPv4。
        server.listenAddressIPv4 = listenAddress
        var lastError: Error?
        let candidates = preferredPorts + (0..<20).map { _ in in_port_t(Int.random(in: 49152...65535)) }
        for port in candidates {
            do {
                try server.start(port, forceIPv4: true)
                return port
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: "FileServer", code: -1)
    }

    func stop() { server.stop() }

    // MARK: - 请求处理

    private func handle(_ req: HttpRequest) -> HttpResponse {
        // 1. 鉴权：query ?t= 或 cookie 任一匹配当前分享的 token（每请求取一次快照，
        //    保证鉴权判断与下面 Set-Cookie 写的是同一把钥匙，轮换瞬间也不串）
        let token = self.token
        let remoteMode = remoteAccessEnabled
        let clientAddress = req.address
        // 网页语言逐请求决定：按浏览器 Accept-Language，与原生 app 设置无关。往下穿进每个 HTML 生产者。
        let lang = Lang.fromAcceptLanguage(req.headers["accept-language"])
        // 收件箱开启：listing 页（同上传表单的出现条件）多挂一张「发文本给电脑」表单。每请求取一次快照。
        let recvOn = textInboxEnabled && !remoteMode
        let viaQuery = req.queryParams.first { $0.0 == "t" }?.1 == token
        let viaCookie = cookieValue("ls_token", in: req.headers["cookie"]) == token
        guard viaQuery || viaCookie else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage(lang))
        }
        if remoteMode && req.method != "GET" && req.method != "HEAD" {
            return jsonResponse(405, "Method Not Allowed", errorJSON(L.remoteReadOnly(lang)), extra: [:])
        }
        // 经 query 放行且尚无（有效）cookie 时，种会话 cookie，后续资源请求免带 token。
        // 不设 Max-Age：随浏览器会话走；token 轮换后旧值反正立即失效。页面 JS 不读它，HttpOnly。
        var extra: [String: String] = [:]
        if viaQuery, !viaCookie {
            extra["Set-Cookie"] = "ls_token=\(token); Path=/; SameSite=Lax; HttpOnly"
        }

        // 鉴权通过的每个请求都刷新该 IP 的活跃时间（含心跳与下载中的请求）。
        touchPresence(clientAddress)

        // 心跳/在线数端点（保留路径，优先于分享内容命中；分享里恰好有 ls/ping 的概率可忽略）。
        // req.path 不含 query（Swifter 用 URLComponents.path），精确比较即可。
        if req.path == "/ls/ping" {
            var h = extra
            h["Cache-Control"] = "no-store"
            return jsonResponse(200, "OK", #"{"viewers":\#(activeViewers())}"#, extra: h)
        }

        // token 清洗：浏览器首次经 ?t= 进入（尚无 cookie、cookie 已在 extra 里种好）时，立刻 302 到
        // 去掉 ?t= 的同一路径——token 不在地址栏/浏览历史里停留，followed 请求带 cookie 鉴权。
        // 仅限浏览器导航（Accept 含 text/html）：curl/脚本、壳页 ?raw=1 取文、图片等子请求（Accept */*）
        // 不受影响，照旧直接拿内容。目录无斜杠会再经下游 301 补斜杠，多一跳但只在首访发生。
        if viaQuery, !viaCookie, req.method == "GET",
           (req.headers["accept"] ?? "").contains("text/html") {
            let rest = req.queryParams.filter { $0.0 != "t" }.map { kv in
                let k = kv.0.addingPercentEncoding(withAllowedCharacters: Self.queryComponentAllowed) ?? kv.0
                let v = kv.1.addingPercentEncoding(withAllowedCharacters: Self.queryComponentAllowed) ?? kv.1
                return "\(k)=\(v)"
            }.joined(separator: "&")
            var h = extra
            h["Location"] = rest.isEmpty ? req.path : "\(req.path)?\(rest)"
            return .raw(302, "Found", h, nil)
        }

        // 注意：Swifter 的 path 解析有 bug，req.path 仍保留一层百分号编码，需手动解码再落地到文件系统。
        // 解码后用于「防穿越 / 面包屑显示」；301 的 Location 仍用 req.path（保持编码，浏览器再请求即可）。
        let decodedPath = req.path.removingPercentEncoding ?? req.path

        // Markdown 预览的内容协商：浏览器导航（Accept 含 text/html）发预览壳页；curl、脚本与
        // 壳页自身的取文 fetch（Accept */*）拿原始文件；?raw=1 为显式逃生门（页角「查看原文」）。
        let rawRequested = req.queryParams.contains { $0.0 == "raw" && $0.1 == "1" }
        let wantsViewer = !rawRequested && (req.headers["accept"] ?? "").contains("text/html")
        let rangeHeader = req.headers["range"]

        // 分享文本端点（保留路径，先于分享内容路由；与 /ls/ping 同款）：导航发文本预览壳页，
        // ?raw=1 / curl（Accept */*）发 text/plain 原文。无分享文本时 404。token 清洗的 302 已在上面处理，
        // 故到这里要么带 cookie 要么是非导航请求，照常服务。
        // 传递文本（收/发合一，保留路径，先于分享内容路由）：二维码恒指此页。
        //  · 有共享文本：导航发文本预览壳页（开着接收时壳页自带发送框，见 PreviewPage canReceiveText），
        //    ?raw=1/curl（Accept */*）发 text/plain 原文；
        //  · 无共享文本但开着接收：退化成纯「发文本给电脑」页（手机→Mac）；
        //  · 两者皆无：没东西可展示，404。token 清洗的 302 已在上面处理。
        if req.method == "GET", req.path == "/ls/text" {
            let text = sharedText ?? ""
            if !text.isEmpty {
                if wantsViewer {
                    // 与文件共存（虚拟根有文件项）时显示「分享内容 / 文本」面包屑；纯文本分享不显示。
                    // 复用 DirectoryListing.breadcrumb（同 md/json/csv 预览）：把「文本」当末段路径传入即得
                    // 「根(链) / 文本(当前)」，样式将来变动这里一并跟随。
                    var crumbs: String? = nil
                    if case .multiple(let items) = share, !items.isEmpty {
                        crumbs = DirectoryListing.breadcrumb(requestPath: "/" + L.webText(lang),
                                                             rootName: Self.multipleRootName(lang))
                    }
                    return htmlResponse(200, "OK", TextViewer.html(text: text, crumbs: crumbs, canUpload: false, canReceiveText: recvOn, lang: lang), extra: extra)
                }
                return plainTextResponse(text, extra: extra)
            }
            if recvOn {
                return htmlResponse(200, "OK", SendText.html(lang: lang), extra: extra)
            }
            return htmlResponse(404, "Not Found", Self.notFoundPage(lang), extra: extra)
        }

        // 旧版「只收文本」二维码曾直指 /ls/send；现已并入 /ls/text（收发合一）。保留此路径做 302 兼容，
        // 让老二维码/书签仍能落地（cookie 已在 token 清洗步种好，跟随重定向即可鉴权）。
        if req.method == "GET", req.path == "/ls/send" {
            var h = extra
            h["Location"] = "/ls/text"
            return .raw(302, "Found", h, nil)
        }

        // 收文本（保留路径，先于上传拦截）：POST /ls/text 投递一段文本到收件箱。开关关 → 403；
        // 超单条上限 → 413；空白 → 400。落库与未读由 onReceiveText 交给 AppState。
        if req.method == "POST", req.path == "/ls/text" {
            return handleReceiveText(req: req, clientAddress: clientAddress, lang: lang, extra: extra)
        }

        // 访客上传：POST 到当前浏览的目录。开关关 / 非文件夹分享一律拒绝（先于单文件分支拦截，
        // 否则单文件模式下 POST 会拿到文件本体）。
        if req.method == "POST" {
            return handleUpload(decodedPath: decodedPath, req: req, lang: lang, extra: extra)
        }

        // 单文件模式：任何路径都只发这一个文件（已过 token），不暴露同目录其它文件。
        // md 预览照常可用（壳页 fetch ?raw=1 时本分支返回文件本体）；相对图片无从谈起，属设计内。
        if case .file(let fileURL) = share {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return htmlResponse(404, "Not Found", Self.notFoundPage(lang), extra: extra)
            }
            return contentResponse(fileURL, viewer: wantsViewer, crumbs: nil, canUpload: false, canReceiveText: recvOn,
                                   lang: lang, extra: extra, range: rangeHeader)
        }

        // 多选模式：虚拟根列出选中项；首段 key 映射到对应真实项后落地（目录项再走子树服务）。
        if case .multiple(let items) = share {
            let rootName = Self.multipleRootName(lang)
            let trimmed = decodedPath.drop { $0 == "/" }
            if trimmed.isEmpty {
                let entries = items.map { (name: $0.key, url: $0.url, isDir: $0.isDir) }
                // 文本与文件共存（或纯文本分享 items 为空）时，虚拟根列表多挂一个指向 /ls/text 的文本行。
                let textRow = sharedText.flatMap { $0.isEmpty ? nil : Self.textPreview($0) }
                return htmlResponse(200, "OK", DirectoryListing.html(items: entries, rootName: rootName, textPreview: textRow, canReceiveText: recvOn, lang: lang), extra: extra)
            }
            var segs = decodedPath.split(separator: "/").map(String.init)
            let key = segs.removeFirst()
            guard let item = items.first(where: { $0.key == key }) else {
                return htmlResponse(404, "Not Found", Self.notFoundPage(lang), extra: extra)
            }
            let rest = segs.joined(separator: "/")
            if !item.isDir {
                // 文件项：不暴露任何子路径。md 项的相对引用恰好可用——虚拟根以 lastPathComponent
                // 为 key，同父目录的兄弟项保持原名，`assets/x.png` 解析到 `/assets/…` 即命中。
                guard rest.isEmpty, FileManager.default.fileExists(atPath: item.url.path) else {
                    return htmlResponse(404, "Not Found", Self.notFoundPage(lang), extra: extra)
                }
                let crumbs = DirectoryListing.breadcrumb(requestPath: decodedPath, rootName: rootName)
                return contentResponse(item.url, viewer: wantsViewer, crumbs: crumbs, canUpload: false, canReceiveText: recvOn,
                                       lang: lang, extra: extra, range: rangeHeader)
            }
            return serveTree(rootURL: item.url, relPath: rest, encodedPath: req.path,
                             decodedPath: decodedPath, rootName: rootName,
                             canUpload: false, canReceiveText: recvOn, viewer: wantsViewer, lang: lang, extra: extra,
                             range: rangeHeader)
        }

        guard case .directory(let rootURL) = share else { return .internalServerError }
        let rel = String(decodedPath.drop { $0 == "/" })
        return serveTree(rootURL: rootURL, relPath: rel, encodedPath: req.path,
                         decodedPath: decodedPath, rootName: rootURL.lastPathComponent,
                         canUpload: uploadEnabled && !remoteMode, canReceiveText: recvOn,
                         viewer: wantsViewer, lang: lang, extra: extra, range: rangeHeader)
    }

    // 可预览类型（md/json/csv）且浏览器导航 → 预览壳页（与文件同 URL，相对引用天然成立）；
    // 其余发文件本体。新增预览类型只需在此登记，壳页骨架见 PreviewPage。
    private func contentResponse(_ url: URL, viewer: Bool, crumbs: String?,
                                 canUpload: Bool, canReceiveText: Bool, lang: Lang, extra: [String: String],
                                 range: String? = nil) -> HttpResponse {
        if viewer, let html = Self.previewHTML(url, crumbs: crumbs, canUpload: canUpload, canReceiveText: canReceiveText, lang: lang) {
            return htmlResponse(200, "OK", html, extra: extra)
        }
        return fileResponse(url, lang: lang, extra: extra, range: range)
    }

    private static func previewHTML(_ url: URL, crumbs: String?, canUpload: Bool, canReceiveText: Bool, lang: Lang) -> String? {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return MarkdownViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload, canReceiveText: canReceiveText, lang: lang)
        case "json", "geojson":
            return JsonViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload, canReceiveText: canReceiveText, lang: lang)
        case "csv", "tsv":
            return CsvViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload, canReceiveText: canReceiveText, lang: lang)
        default:
            return nil
        }
    }

    // 防目录穿越的唯一判据（serveTree 与 handleUpload 共用）：把 relPath 拼到 root 后标准化、
    // 解符号链接，结果必须仍落在 root 内（root 自身或其子路径）——杜绝 ../、绝对路径、以及指向
    // 外部的符号链接。安全则返回解析后的真实 URL，逃逸返回 nil。relPath 须已解码（上游已做
    // removingPercentEncoding，故 %2e%2e / ..%2f 解码成 .. 后同样被挡）。
    static func resolveWithinRoot(_ rootURL: URL, relPath: String) -> URL? {
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let target = rootURL.appendingPathComponent(relPath).standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else { return nil }
        return target
    }

    // 在 rootURL 这棵子树内服务请求：防穿越 → 目录(301 补斜杠 / index.html / 列表页) → 文件流式发送
    //（md 文件且 viewer=true 时发预览壳页）。relPath：相对 rootURL 的路径（已解码、去前导斜杠）；
    // encodedPath：用于 301 Location 的原始请求路径（保留编码）；
    // decodedPath：用于列表页面包屑/标题的解码请求路径；rootName：列表页与面包屑的根名。
    // 单根目录与多选里的每个目录项共用此函数（多选时 rootURL=项目本身、relPath=去掉 key 段后的剩余）。
    private func serveTree(rootURL: URL, relPath: String, encodedPath: String,
                           decodedPath: String, rootName: String, canUpload: Bool,
                           canReceiveText: Bool, viewer: Bool, lang: Lang, extra: [String: String],
                           range: String? = nil) -> HttpResponse {
        // 防目录穿越：判据抽进 resolveWithinRoot，与 handleUpload 共用一份，避免两处漂移。
        guard let target = Self.resolveWithinRoot(rootURL, relPath: relPath) else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage(lang))
        }
        let targetPath = target.path

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetPath, isDirectory: &isDir) else {
            return htmlResponse(404, "Not Found", Self.notFoundPage(lang), extra: extra)
        }

        if isDir.boolValue {
            // 无 trailing slash 的目录先 301 加斜杠，保证 index.html 里的相对资源能正确解析
            if !encodedPath.hasSuffix("/") {
                var headers = extra
                headers["Location"] = encodedPath + "/"
                return .raw(301, "Moved Permanently", headers, nil)
            }
            let indexURL = target.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexURL.path) {
                return fileResponse(indexURL, lang: lang, extra: extra, range: range)
            }
            let html = DirectoryListing.html(directory: target, requestPath: decodedPath,
                                             rootName: rootName, canUpload: canUpload,
                                             canReceiveText: canReceiveText, lang: lang)
            return htmlResponse(200, "OK", html, extra: extra)
        }

        let crumbs = DirectoryListing.breadcrumb(requestPath: decodedPath, rootName: rootName)
        return contentResponse(target, viewer: viewer, crumbs: crumbs, canUpload: canUpload, canReceiveText: canReceiveText,
                               lang: lang, extra: extra, range: range)
    }

    // MARK: - 收文本处理

    // POST /ls/text（手机→Mac）：收一段纯文本投递进收件箱。请求体即原文（text/plain，前端 fetch 直接发
    // textarea 内容，不走表单编码——免去 + / % 的歧义，body.count 即字节数，单条上限判得干净）。
    // 安全：闸门 textInboxEnabled 把关；超 textInboxLimit → 413；去首尾空白后为空 → 400。
    // 收到的文本经 onReceiveText 交 AppState（socket 线程，设置方 hop 主线程入收件箱）；FileServer 不存列表。
    // 文本本身不回显进任何服务页（仅在 Mac 端 SwiftUI Text 里显示，天然不执行），故无须额外转义。
    private func handleReceiveText(req: HttpRequest, clientAddress: String?, lang: Lang,
                                   extra: [String: String]) -> HttpResponse {
        guard textInboxEnabled && !remoteAccessEnabled else {
            return jsonResponse(403, "Forbidden", errorJSON(L.recvDisabled(lang)), extra: extra)
        }
        guard req.body.count <= Self.textInboxLimit else {
            return jsonResponse(413, "Payload Too Large", errorJSON(L.recvOverLimit(lang)), extra: extra)
        }
        let raw = String(decoding: req.body, as: UTF8.self)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return jsonResponse(400, "Bad Request", errorJSON(L.recvEmpty(lang)), extra: extra)
        }
        let ip = clientAddress ?? ""
        lock.lock(); let name = nameCache[ip] ?? ""; lock.unlock()   // 反查到则带设备名，否则展示层回退 IP
        onReceiveText?(ReceivedText(text: trimmed, ip: ip, name: name, date: Date()))
        return jsonResponse(200, "OK", #"{"ok":true}"#, extra: extra)
    }

    // MARK: - 上传处理

    // POST multipart/form-data → 写入访客当前浏览的目录。
    // 安全：开关 + 仅 .directory 分享；目标目录过与读取同一套防穿越校验；
    // 文件名只取末段并清洗；重名 -2 兜底（同 makeItems 策略）；先写临时文件再原子换名。
    private func handleUpload(decodedPath: String, req: HttpRequest, lang: Lang, extra: [String: String]) -> HttpResponse {
        guard uploadEnabled, case .directory(let rootURL) = share else {
            return jsonResponse(403, "Forbidden", errorJSON(L.upDisabled(lang)), extra: extra)
        }
        guard req.body.count <= Self.uploadLimit else {
            return jsonResponse(413, "Payload Too Large", errorJSON(L.upOverLimit(lang)), extra: extra)
        }

        // 落点目录：同 serveTree 的防穿越判据（共用 resolveWithinRoot）
        let rel = String(decodedPath.drop { $0 == "/" })
        guard let target = Self.resolveWithinRoot(rootURL, relPath: rel) else {
            return jsonResponse(403, "Forbidden", errorJSON(L.upPathDenied(lang)), extra: extra)
        }
        let targetPath = target.path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue else {
            return jsonResponse(404, "Not Found", errorJSON(L.upDirMissing(lang)), extra: extra)
        }

        let fileParts = req.parseMultiPartFormData().filter { $0.fileName != nil }
        var saved: [String] = []
        for part in fileParts {
            guard let name = Self.sanitizeFileName(part.fileName) else { continue }
            let dest = Self.availableURL(in: target, name: name)
            do {
                // itemReplacementDirectory 保证与目标同卷，moveItem 才是原子换名而非跨卷拷贝
                let tmpDir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                        appropriateFor: target, create: true)
                let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
                try Data(part.body).write(to: tmp)
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                return jsonResponse(500, "Internal Server Error", errorJSON(L.upWriteFailed(lang)), extra: extra)
            }
            Self.markQuarantine(dest)
            saved.append(dest.lastPathComponent)
            onUpload?(dest)
        }
        guard !saved.isEmpty else {
            return jsonResponse(400, "Bad Request", errorJSON(L.upNoFiles(lang)), extra: extra)
        }
        let names = saved.map { "\"\(Self.jsonEscape($0))\"" }.joined(separator: ",")
        return jsonResponse(200, "OK", #"{"saved":[\#(names)]}"#, extra: extra)
    }

    // 文件名清洗：只取末段（防 ../ 与绝对路径）、剔除控制符、":" 换 "-"（Finder 的路径分隔）；
    // 点开头（隐藏文件）、空名、"."/".." 一律拒绝。
    // 末了给「浏览器作为顶层文档打开时会执行其中脚本」的扩展名（HTML/SVG 家族）追加 .txt 去势：
    // 访客上传的内容落在分享源（http://本机:端口）下，若以 text/html、image/svg+xml 原样发出会被
    // 当成同源页面执行脚本（存储型 XSS）；尤其传一个 index.html 会顶替目录列表页、别人点进该目录
    // 即零点击中招。改名后落地为 text/plain，保留文件本体但不再执行、也不会成为目录默认页。
    // 仅作用于访客上传路径；分享者自己放进文件夹的静态站点经 .directory 直接服务、不过此函数，
    // 故「分享一个含 index.html 的站点目录」照常工作，不受影响。
    static func sanitizeFileName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var name = (raw as NSString).lastPathComponent
        name = String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.hasPrefix(".") else { return nil }
        if executableDocExtensions.contains((name as NSString).pathExtension.lowercased()) {
            name += ".txt"
        }
        return name
    }

    // 浏览器把它当顶层文档打开时会执行内嵌脚本的类型（HTML/SVG 家族）。访客上传命中即去势。
    private static let executableDocExtensions: Set<String> = [
        "html", "htm", "xhtml", "xht", "shtml", "svg", "svgz", "mht", "mhtml",
    ]

    // 给访客上传落地的文件打上 com.apple.quarantine 隔离属性：分享者之后在 Finder 双击时，与
    // 「从浏览器下载的文件」享同等 Gatekeeper 待遇（弹来源确认 / 触发公证校验），降低被诱导直接
    // 打开局域网他人投放文件的风险。纯 setxattr（libSystem），不引包外 dylib；best-effort，失败
    // 不影响上传成功。值格式：<flags>;<hex 时间戳>;<来源 agent>;<UUID>。
    private static func markQuarantine(_ url: URL) {
        let stamp = String(format: "%lx", UInt(max(0, Date().timeIntervalSince1970)))
        let value = "0181;\(stamp);LocalShare;\(UUID().uuidString)"
        _ = value.withCString { v in
            url.path.withCString { p in
                setxattr(p, "com.apple.quarantine", v, strlen(v), 0, 0)
            }
        }
    }

    // 目标已存在则在扩展名前追加 -2/-3…（与 Share.makeItems 的 key 兜底同款策略）。
    static func availableURL(in dir: URL, name: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var n = 2
        repeat {
            let next = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    private static func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // 上传错误 JSON：{"error":"<已本地化文案>"}，文案经 jsonEscape 兜底（现有文案本无引号，仍防御）。
    private func errorJSON(_ message: String) -> String {
        #"{"error":"\#(Self.jsonEscape(message))"}"#
    }

    private func jsonResponse(_ code: Int, _ reason: String, _ json: String, extra: [String: String]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = "application/json"
        headers["X-Content-Type-Options"] = "nosniff"
        let body = Data(json.utf8)
        return .raw(code, reason, headers) { writer in try? writer.write(body) }
    }

    private func fileResponse(_ url: URL, lang: Lang, extra: [String: String], range: String? = nil) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = Mime.contentType(forExtension: url.pathExtension)
        // 关掉浏览器的 MIME 猜测兜底：一律按上面声明的类型处理。已正确声明类型的文件照常内联显示，
        // 未知类型本就回退 octet-stream 下载——nosniff 只是确保它不会被某些浏览器猜成 HTML 执行。
        headers["X-Content-Type-Options"] = "nosniff"
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        headers["Accept-Ranges"] = "bytes"
        var status = 200
        var start: Int64 = 0
        var length = size
        if let range, !range.isEmpty {
            guard let selected = Self.byteRange(range, size: size) else {
                headers["Content-Range"] = "bytes */\(size)"
                headers["Content-Length"] = "0"
                return .raw(416, "Range Not Satisfiable", headers, nil)
            }
            status = 206
            start = selected.start
            length = selected.end - selected.start + 1
            headers["Content-Range"] = "bytes \(selected.start)-\(selected.end)/\(size)"
        }
        headers["Content-Length"] = String(length)
        return .raw(status, status == 206 ? "Partial Content" : "OK", headers) { writer in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                try? writer.write(Data(L.webReadFailed(lang).utf8))
                return
            }
            defer { try? handle.close() }
            if start > 0 { try? handle.seek(toOffset: UInt64(start)) }
            var remaining = length
            while remaining > 0 {
                let chunk = handle.readData(ofLength: Int(min(Int64(64 * 1024), remaining)))
                if chunk.isEmpty { break }
                try writer.write(chunk)
                remaining -= Int64(chunk.count)
            }
        }
    }

    static func byteRange(_ header: String, size: Int64) -> (start: Int64, end: Int64)? {
        guard size > 0,
              header.lowercased().hasPrefix("bytes="),
              let value = header.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false).first,
              !header.dropFirst(6).contains(","),
              let dash = value.firstIndex(of: "-") else { return nil }
        let first = value[..<dash].trimmingCharacters(in: .whitespaces)
        let last = value[value.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if first.isEmpty {
            guard let suffix = Int64(last), suffix > 0 else { return nil }
            return (max(0, size - suffix), size - 1)
        }
        guard let start = Int64(first), start >= 0, start < size else { return nil }
        let end = last.isEmpty ? size - 1 : (Int64(last) ?? -1)
        guard end >= start else { return nil }
        return (start, min(end, size - 1))
    }

    // 分享文本的原文响应（?raw=1 / curl）：text/plain；带 Content-Length 让客户端显示进度、知道何时收完。
    private func plainTextResponse(_ text: String, extra: [String: String]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = "text/plain; charset=utf-8"
        headers["X-Content-Type-Options"] = "nosniff"
        let body = Data(text.utf8)
        headers["Content-Length"] = String(body.count)
        return .raw(200, "OK", headers) { writer in try? writer.write(body) }
    }

    private func htmlResponse(_ code: Int, _ reason: String, _ html: String, extra: [String: String] = [:]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = "text/html; charset=utf-8"
        headers["X-Content-Type-Options"] = "nosniff"
        return .raw(code, reason, headers) { writer in
            try? writer.write(Data(html.utf8))
        }
    }

    private func cookieValue(_ key: String, in header: String?) -> String? {
        guard let header else { return nil }
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == key { return kv[1] }
        }
        return nil
    }

    private static func forbiddenPage(_ lang: Lang) -> String {
        """
        <!doctype html><html lang="\(lang.htmlLang)"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <body style="font-family:-apple-system,sans-serif;text-align:center;padding:48px 24px;color:#444">
        <h2>🔒 \(L.webForbiddenTitle(lang))</h2><p>\(L.webForbiddenBody(lang))</p></body></html>
        """
    }

    private static func notFoundPage(_ lang: Lang) -> String {
        "<!doctype html><html lang=\"\(lang.htmlLang)\"><meta charset=\"utf-8\"><h2>404</h2><p>\(L.webFileNotFound(lang))</p></html>"
    }
}
