import Foundation
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

    // 多选虚拟根的显示名（列表页 H1 / 面包屑根）。多选无共同磁盘根，故给个中性名。
    static let multipleRootName = "分享内容"

    private let server = HttpServer()

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
        set { lock.lock(); _token = newValue; lastSeen = [:]; lock.unlock() }
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

    private func touchPresence(_ ip: String?) {
        guard let ip, !ip.isEmpty else { return }
        lock.lock(); lastSeen[ip] = Date(); lock.unlock()
    }

    // 活跃访客数。GUI 定时轮询 + 心跳响应均走这里；顺手剔除窗口外条目，字典不会无限增长。
    func activeViewers() -> Int {
        let cutoff = Date().addingTimeInterval(-Self.presenceWindow)
        lock.lock(); defer { lock.unlock() }
        lastSeen = lastSeen.filter { $0.value > cutoff }
        return lastSeen.count
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
        let viaQuery = req.queryParams.first { $0.0 == "t" }?.1 == token
        let viaCookie = cookieValue("ls_token", in: req.headers["cookie"]) == token
        guard viaQuery || viaCookie else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage)
        }
        // 经 query 放行且尚无（有效）cookie 时，种会话 cookie，后续资源请求免带 token。
        // 不设 Max-Age：随浏览器会话走；token 轮换后旧值反正立即失效。页面 JS 不读它，HttpOnly。
        var extra: [String: String] = [:]
        if viaQuery, !viaCookie {
            extra["Set-Cookie"] = "ls_token=\(token); Path=/; SameSite=Lax; HttpOnly"
        }

        // 鉴权通过的每个请求都刷新该 IP 的活跃时间（含心跳与下载中的请求）。
        touchPresence(req.address)

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

        // 访客上传：POST 到当前浏览的目录。开关关 / 非文件夹分享一律拒绝（先于单文件分支拦截，
        // 否则单文件模式下 POST 会拿到文件本体）。
        if req.method == "POST" {
            return handleUpload(decodedPath: decodedPath, req: req, extra: extra)
        }

        // 单文件模式：任何路径都只发这一个文件（已过 token），不暴露同目录其它文件。
        // md 预览照常可用（壳页 fetch ?raw=1 时本分支返回文件本体）；相对图片无从谈起，属设计内。
        if case .file(let fileURL) = share {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
            }
            return contentResponse(fileURL, viewer: wantsViewer, crumbs: nil, canUpload: false, extra: extra)
        }

        // 多选模式：虚拟根列出选中项；首段 key 映射到对应真实项后落地（目录项再走子树服务）。
        if case .multiple(let items) = share {
            let trimmed = decodedPath.drop { $0 == "/" }
            if trimmed.isEmpty {
                let entries = items.map { (name: $0.key, url: $0.url, isDir: $0.isDir) }
                return htmlResponse(200, "OK", DirectoryListing.html(items: entries, rootName: Self.multipleRootName), extra: extra)
            }
            var segs = decodedPath.split(separator: "/").map(String.init)
            let key = segs.removeFirst()
            guard let item = items.first(where: { $0.key == key }) else {
                return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
            }
            let rest = segs.joined(separator: "/")
            if !item.isDir {
                // 文件项：不暴露任何子路径。md 项的相对引用恰好可用——虚拟根以 lastPathComponent
                // 为 key，同父目录的兄弟项保持原名，`assets/x.png` 解析到 `/assets/…` 即命中。
                guard rest.isEmpty, FileManager.default.fileExists(atPath: item.url.path) else {
                    return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
                }
                let crumbs = DirectoryListing.breadcrumb(requestPath: decodedPath, rootName: Self.multipleRootName)
                return contentResponse(item.url, viewer: wantsViewer, crumbs: crumbs, canUpload: false, extra: extra)
            }
            return serveTree(rootURL: item.url, relPath: rest, encodedPath: req.path,
                             decodedPath: decodedPath, rootName: Self.multipleRootName,
                             canUpload: false, viewer: wantsViewer, extra: extra)
        }

        guard case .directory(let rootURL) = share else { return .internalServerError }
        let rel = String(decodedPath.drop { $0 == "/" })
        return serveTree(rootURL: rootURL, relPath: rel, encodedPath: req.path,
                         decodedPath: decodedPath, rootName: rootURL.lastPathComponent,
                         canUpload: uploadEnabled, viewer: wantsViewer, extra: extra)
    }

    // 可预览类型（md/json/csv）且浏览器导航 → 预览壳页（与文件同 URL，相对引用天然成立）；
    // 其余发文件本体。新增预览类型只需在此登记，壳页骨架见 PreviewPage。
    private func contentResponse(_ url: URL, viewer: Bool, crumbs: String?,
                                 canUpload: Bool, extra: [String: String]) -> HttpResponse {
        if viewer, let html = Self.previewHTML(url, crumbs: crumbs, canUpload: canUpload) {
            return htmlResponse(200, "OK", html, extra: extra)
        }
        return fileResponse(url, extra: extra)
    }

    private static func previewHTML(_ url: URL, crumbs: String?, canUpload: Bool) -> String? {
        let name = url.lastPathComponent
        switch url.pathExtension.lowercased() {
        case "md", "markdown":
            return MarkdownViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload)
        case "json", "geojson":
            return JsonViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload)
        case "csv", "tsv":
            return CsvViewer.html(fileName: name, crumbs: crumbs, canUpload: canUpload)
        default:
            return nil
        }
    }

    // 在 rootURL 这棵子树内服务请求：防穿越 → 目录(301 补斜杠 / index.html / 列表页) → 文件流式发送
    //（md 文件且 viewer=true 时发预览壳页）。relPath：相对 rootURL 的路径（已解码、去前导斜杠）；
    // encodedPath：用于 301 Location 的原始请求路径（保留编码）；
    // decodedPath：用于列表页面包屑/标题的解码请求路径；rootName：列表页与面包屑的根名。
    // 单根目录与多选里的每个目录项共用此函数（多选时 rootURL=项目本身、relPath=去掉 key 段后的剩余）。
    private func serveTree(rootURL: URL, relPath: String, encodedPath: String,
                           decodedPath: String, rootName: String, canUpload: Bool,
                           viewer: Bool, extra: [String: String]) -> HttpResponse {
        // 防目录穿越：拼接后标准化解符号链接，结果必须仍落在 root 内（杜绝 ../、%2e%2e、..%2f）。
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let target = rootURL.appendingPathComponent(relPath).standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetPath, isDirectory: &isDir) else {
            return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
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
                return fileResponse(indexURL, extra: extra)
            }
            let html = DirectoryListing.html(directory: target, requestPath: decodedPath,
                                             rootName: rootName, canUpload: canUpload)
            return htmlResponse(200, "OK", html, extra: extra)
        }

        let crumbs = DirectoryListing.breadcrumb(requestPath: decodedPath, rootName: rootName)
        return contentResponse(target, viewer: viewer, crumbs: crumbs, canUpload: canUpload, extra: extra)
    }

    // MARK: - 上传处理

    // POST multipart/form-data → 写入访客当前浏览的目录。
    // 安全：开关 + 仅 .directory 分享；目标目录过与读取同一套防穿越校验；
    // 文件名只取末段并清洗；重名 -2 兜底（同 makeItems 策略）；先写临时文件再原子换名。
    private func handleUpload(decodedPath: String, req: HttpRequest, extra: [String: String]) -> HttpResponse {
        guard uploadEnabled, case .directory(let rootURL) = share else {
            return jsonResponse(403, "Forbidden", #"{"error":"上传未开启"}"#, extra: extra)
        }
        guard req.body.count <= Self.uploadLimit else {
            return jsonResponse(413, "Payload Too Large", #"{"error":"超过 500MB 上限"}"#, extra: extra)
        }

        // 落点目录：同 serveTree 的防穿越判据
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let rel = String(decodedPath.drop { $0 == "/" })
        let target = rootURL.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            return jsonResponse(403, "Forbidden", #"{"error":"路径不允许"}"#, extra: extra)
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetPath, isDirectory: &isDir), isDir.boolValue else {
            return jsonResponse(404, "Not Found", #"{"error":"目录不存在"}"#, extra: extra)
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
                return jsonResponse(500, "Internal Server Error", #"{"error":"写入失败"}"#, extra: extra)
            }
            Self.markQuarantine(dest)
            saved.append(dest.lastPathComponent)
            onUpload?(dest)
        }
        guard !saved.isEmpty else {
            return jsonResponse(400, "Bad Request", #"{"error":"没有可保存的文件"}"#, extra: extra)
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

    private func jsonResponse(_ code: Int, _ reason: String, _ json: String, extra: [String: String]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = "application/json"
        headers["X-Content-Type-Options"] = "nosniff"
        let body = Data(json.utf8)
        return .raw(code, reason, headers) { writer in try? writer.write(body) }
    }

    private func fileResponse(_ url: URL, extra: [String: String]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = Mime.contentType(forExtension: url.pathExtension)
        // 关掉浏览器的 MIME 猜测兜底：一律按上面声明的类型处理。已正确声明类型的文件照常内联显示，
        // 未知类型本就回退 octet-stream 下载——nosniff 只是确保它不会被某些浏览器猜成 HTML 执行。
        headers["X-Content-Type-Options"] = "nosniff"
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            headers["Content-Length"] = String(size)
        }
        return .raw(200, "OK", headers) { writer in
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                try? writer.write(Data("读取失败".utf8))
                return
            }
            defer { try? handle.close() }
            while true {
                let chunk = handle.readData(ofLength: 64 * 1024)
                if chunk.isEmpty { break }
                try writer.write(chunk)
            }
        }
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

    private static let forbiddenPage = """
    <!doctype html><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <body style="font-family:-apple-system,sans-serif;text-align:center;padding:48px 24px;color:#444">
    <h2>🔒 无法访问</h2><p>请通过电脑上显示的二维码扫码进入。</p></body>
    """
}
