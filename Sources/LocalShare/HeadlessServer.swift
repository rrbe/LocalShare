import Foundation

// 无界面运行模式（LS_HEADLESS=1）：仅启动 FileServer 并阻塞，供测试/自动化使用。
// 通过环境变量配置：
//   LS_FOLDER   要服务的单个文件/文件夹（与 LS_FOLDERS 二选一）
//   LS_FOLDERS  多项：以 ':' 或换行分隔的多个路径（走多选虚拟根）
//   LS_TOKEN    访问令牌（选填，默认 testtoken）
//   LS_PORT     端口（选填，默认 8080）
//   LS_UPLOAD   置 1 开启访客上传（仅单文件夹分享生效）
//   LS_BIND     仅绑该 IPv4 地址（选填；默认绑全部接口）——对应 GUI「仅当前网络可见」，供冒烟验证
//   LS_TEXT     分享一段文本（可单独，也可与 LS_FOLDER(S) 共存）；纯文本时 URL 直指 /ls/text
//   LS_RECV     置 1 开启收文本（收件箱）；无任何分享内容时 URL 直指 /ls/send
//   LS_RECV_LOG 收到文本时把原文追加进该文件（以 0x01 分隔），供冒烟测回读校验
enum HeadlessServer {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        let token = env["LS_TOKEN"] ?? "testtoken"
        let port = in_port_t(env["LS_PORT"].flatMap { Int($0) } ?? 8080)
        let text = env["LS_TEXT"].flatMap { $0.isEmpty ? nil : $0 }
        let recvOn = env["LS_RECV"] == "1"

        let paths: [String]
        if let multi = env["LS_FOLDERS"] {
            paths = multi.split(whereSeparator: { $0 == ":" || $0 == "\n" }).map(String.init)
        } else if let single = env["LS_FOLDER"] {
            paths = [single]
        } else if text != nil || recvOn {
            paths = []   // 纯文本分享 / 只收文本：无文件项
        } else {
            FileHandle.standardError.write(Data((L.hsEnvMissing(Lang.systemDefault) + "\n").utf8))
            exit(2)
        }

        let urls = paths.map { URL(fileURLWithPath: $0) }
        let server = FileServer(share: makeShare(urls, hasText: text != nil), token: token)
        server.uploadEnabled = env["LS_UPLOAD"] == "1"
        server.listenAddress = env["LS_BIND"]   // nil → 全部接口（默认）
        server.sharedText = text
        server.textInboxEnabled = recvOn
        if let logPath = env["LS_RECV_LOG"] {
            server.onReceiveText = { rt in   // socket 线程：把原文追加进日志文件，供冒烟测回读
                let chunk = Data((rt.text + "\u{1}").utf8)
                if let h = FileHandle(forWritingAtPath: logPath) {
                    h.seekToEndOfFile(); h.write(chunk); try? h.close()
                } else {
                    try? chunk.write(to: URL(fileURLWithPath: logPath))
                }
            }
        }
        do {
            let bound = try server.start(preferredPorts: [port])
            // 纯文本分享直指 /ls/text、只收文本直指 /ls/send（口径同 GUI 的 AppState.makeURL）。
            let path: String
            if text != nil, urls.isEmpty { path = "/ls/text" }
            else if recvOn, urls.isEmpty, text == nil { path = "/ls/send" }
            else { path = "/" }
            print("LS_URL http://127.0.0.1:\(bound)\(path)?t=\(token)")
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data((LStr.hsStartFailed("\(error)", Lang.systemDefault) + "\n").utf8))
            exit(1)
        }
        RunLoop.main.run()
    }

    // CLI 前台模式（`localshare --headless <路径>…`）：随机 token、局域网地址、终端二维码。
    // 与上面的 LS_HEADLESS 环境变量路径并存：脚本/自动化继续用固定 token 的老路径，互不干扰。
    // 注意：参数刻意收具体端口数组而非 Optional——Swift 6.2.4 的 -O 在「枚举载荷 Optional →
    // 本函数内构造数组 → 传入 start」这条链上会错编出垃圾数组指针（release 必崩，debug 正常），
    // 把 Optional 的展开挪到调用方可绕开。改这里务必用 release 构建重跑 --port/无 --port 冒烟。
    static func runForeground(urls: [URL], preferredPorts: [in_port_t]) {
        let token = Token.generate()
        let server = FileServer(share: makeShare(urls, hasText: false), token: token)
        do {
            let bound = try server.start(preferredPorts: preferredPorts)
            let ip = NetworkInfo.privateIPv4Interfaces().first?.ip
            if ip == nil {
                FileHandle.standardError.write(Data((L.hsNoLan(Lang.systemDefault) + "\n").utf8))
            }
            // 单文件分享直链该文件（口径同 GUI 的 AppState.makeURL）。
            var path = "/"
            if urls.count == 1 {
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir)
                if !isDir.boolValue,
                   let enc = urls[0].lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
                    path = "/\(enc)"
                }
            }
            let url = "http://\(ip ?? "127.0.0.1"):\(bound)\(path)?t=\(token)"
            print("LS_URL \(url)")
            // 二维码只在交互终端打印；输出被管道接走时保持纯文本，方便脚本取 URL。
            if isatty(STDOUT_FILENO) != 0 {
                if let qr = QRCode.ansi(for: url) { print("\n\(qr)") }
                print(L.hsScanHint(Lang.systemDefault))
            }
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data((LStr.hsStartFailed("\(error)", Lang.systemDefault) + "\n").utf8))
            exit(1)
        }
        RunLoop.main.run()
        exit(0)
    }

    // 路径集合 → 分享形态：单项判文件/文件夹，多项走虚拟根。
    // 有文本时一律走虚拟根（口径同 GUI 的 AppState.currentShare）：纯文本 → 空虚拟根 .multiple([])；
    // 文本+文件 → 文件项的虚拟根（文本经 server.sharedText 单独挂上，不进 items）。
    private static func makeShare(_ urls: [URL], hasText: Bool) -> FileServer.Share {
        if urls.isEmpty { return .multiple([]) }   // 纯文本 / 只收文本：空虚拟根
        if hasText { return .multiple(FileServer.Share.makeItems(urls)) }
        if urls.count > 1 { return .multiple(FileServer.Share.makeItems(urls)) }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir)
        return isDir.boolValue ? .directory(urls[0]) : .file(urls[0])
    }
}
