import Foundation
import Swifter

// 基于 Swifter 的只读静态文件服务。
// 全部逻辑放进单个 middleware 闭包（永远返回 response），绕开 router。
// 安全：① token 鉴权（query 或 cookie）；② 防目录穿越（路径解析后必须仍在所选文件夹内）。
final class FileServer {
    // 分享对象：整个文件夹，或单个文件（扫码直接打开它，不暴露同目录其它文件）。
    enum Share {
        case directory(URL)
        case file(URL)
    }

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
        let viaCookie = cookieValue("lfs_token", in: req.headers["cookie"]) == token
        guard viaQuery || viaCookie else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage)
        }
        // 经 query 放行且尚无 cookie 时，种 cookie，后续资源请求免带 token
        var extra: [String: String] = [:]
        if viaQuery, !viaCookie {
            extra["Set-Cookie"] = "lfs_token=\(token); Path=/; Max-Age=86400; SameSite=Lax"
        }

        // 单文件模式：任何路径都只发这一个文件（已过 token），不暴露同目录其它文件
        if case .file(let fileURL) = share {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>", extra: extra)
            }
            return fileResponse(fileURL, extra: extra)
        }
        guard case .directory(let rootURL) = share else { return .internalServerError }

        // 2. 防目录穿越：拼接后标准化，必须仍落在 root 内
        // 注意：Swifter 的 path 解析有 bug，req.path 仍保留一层百分号编码，需手动解码再落地到文件系统。
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let decodedPath = req.path.removingPercentEncoding ?? req.path
        let rel = String(decodedPath.drop { $0 == "/" })
        let target = rootURL.appendingPathComponent(rel).standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = target.path
        guard targetPath == rootPath || targetPath.hasPrefix(rootPath + "/") else {
            return htmlResponse(403, "Forbidden", Self.forbiddenPage)
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetPath, isDirectory: &isDir) else {
            return htmlResponse(404, "Not Found", "<h2>404</h2><p>文件不存在</p>")
        }

        // 3. 目录处理
        if isDir.boolValue {
            // 无 trailing slash 的目录先 301 加斜杠，保证 index.html 里的相对资源能正确解析
            if !req.path.hasSuffix("/") {
                var headers = extra
                headers["Location"] = req.path + "/"
                return .raw(301, "Moved Permanently", headers, nil)
            }
            let indexURL = target.appendingPathComponent("index.html")
            if fm.fileExists(atPath: indexURL.path) {
                return fileResponse(indexURL, extra: extra)
            }
            let html = DirectoryListing.html(directory: target, requestPath: decodedPath, rootName: rootURL.lastPathComponent)
            return htmlResponse(200, "OK", html, extra: extra)
        }

        // 4. 文件流式发送
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
