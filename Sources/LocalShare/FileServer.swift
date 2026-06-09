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
    private let token: String

    // share 可能在运行中被“更换”修改，故加锁；请求处理在后台 socket 线程读取。
    private let lock = NSLock()
    private var _share: Share
    var share: Share {
        get { lock.lock(); defer { lock.unlock() }; return _share }
        set { lock.lock(); _share = newValue; lock.unlock() }
    }

    init(share: Share, token: String) {
        self._share = share
        self.token = token
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
        // 1. 鉴权：query ?t= 或 cookie 任一匹配本会话 token
        let viaQuery = req.queryParams.first { $0.0 == "t" }?.1 == token
        let viaCookie = cookieValue("ls_token", in: req.headers["cookie"]) == token
        guard viaQuery || viaCookie else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage)
        }
        // 经 query 放行且尚无 cookie 时，种 cookie，后续资源请求免带 token
        var extra: [String: String] = [:]
        if viaQuery, !viaCookie {
            extra["Set-Cookie"] = "ls_token=\(token); Path=/; Max-Age=86400; SameSite=Lax"
        }

        // 单文件模式：任何路径都只发这一个文件（已过 token），不暴露同目录其它文件
        if case .file(let fileURL) = share {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
            }
            return fileResponse(fileURL, extra: extra)
        }

        // 注意：Swifter 的 path 解析有 bug，req.path 仍保留一层百分号编码，需手动解码再落地到文件系统。
        // 解码后用于「防穿越 / 面包屑显示」；301 的 Location 仍用 req.path（保持编码，浏览器再请求即可）。
        let decodedPath = req.path.removingPercentEncoding ?? req.path

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
                // 文件项：不暴露任何子路径
                guard rest.isEmpty, FileManager.default.fileExists(atPath: item.url.path) else {
                    return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
                }
                return fileResponse(item.url, extra: extra)
            }
            return serveTree(rootURL: item.url, relPath: rest, encodedPath: req.path,
                             decodedPath: decodedPath, rootName: Self.multipleRootName, extra: extra)
        }

        guard case .directory(let rootURL) = share else { return .internalServerError }
        let rel = String(decodedPath.drop { $0 == "/" })
        return serveTree(rootURL: rootURL, relPath: rel, encodedPath: req.path,
                         decodedPath: decodedPath, rootName: rootURL.lastPathComponent, extra: extra)
    }

    // 在 rootURL 这棵子树内服务请求：防穿越 → 目录(301 补斜杠 / index.html / 列表页) → 文件流式发送。
    // relPath：相对 rootURL 的路径（已解码、去前导斜杠）；encodedPath：用于 301 Location 的原始请求路径（保留编码）；
    // decodedPath：用于列表页面包屑/标题的解码请求路径；rootName：列表页与面包屑的根名。
    // 单根目录与多选里的每个目录项共用此函数（多选时 rootURL=项目本身、relPath=去掉 key 段后的剩余）。
    private func serveTree(rootURL: URL, relPath: String, encodedPath: String,
                           decodedPath: String, rootName: String, extra: [String: String]) -> HttpResponse {
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
            let html = DirectoryListing.html(directory: target, requestPath: decodedPath, rootName: rootName)
            return htmlResponse(200, "OK", html, extra: extra)
        }

        return fileResponse(target, extra: extra)
    }

    private func fileResponse(_ url: URL, extra: [String: String]) -> HttpResponse {
        var headers = extra
        headers["Content-Type"] = Mime.contentType(forExtension: url.pathExtension)
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
