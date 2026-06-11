import Foundation

// 无界面运行模式（LS_HEADLESS=1）：仅启动 FileServer 并阻塞，供测试/自动化使用。
// 通过环境变量配置：
//   LS_FOLDER   要服务的单个文件/文件夹（与 LS_FOLDERS 二选一）
//   LS_FOLDERS  多项：以 ':' 或换行分隔的多个路径（走多选虚拟根）
//   LS_TOKEN    访问令牌（选填，默认 testtoken）
//   LS_PORT     端口（选填，默认 8080）
//   LS_UPLOAD   置 1 开启访客上传（仅单文件夹分享生效）
enum HeadlessServer {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        let token = env["LS_TOKEN"] ?? "testtoken"
        let port = in_port_t(env["LS_PORT"].flatMap { Int($0) } ?? 8080)

        let paths: [String]
        if let multi = env["LS_FOLDERS"] {
            paths = multi.split(whereSeparator: { $0 == ":" || $0 == "\n" }).map(String.init)
        } else if let single = env["LS_FOLDER"] {
            paths = [single]
        } else {
            FileHandle.standardError.write(Data("LS_FOLDER / LS_FOLDERS 未设置\n".utf8))
            exit(2)
        }

        let urls = paths.map { URL(fileURLWithPath: $0) }
        let server = FileServer(share: makeShare(urls), token: token)
        server.uploadEnabled = env["LS_UPLOAD"] == "1"
        do {
            let bound = try server.start(preferredPorts: [port])
            print("LS_URL http://127.0.0.1:\(bound)/?t=\(token)")
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data("启动失败: \(error)\n".utf8))
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
        let server = FileServer(share: makeShare(urls), token: token)
        do {
            let bound = try server.start(preferredPorts: preferredPorts)
            let ip = NetworkInfo.privateIPv4Interfaces().first?.ip
            if ip == nil {
                FileHandle.standardError.write(Data("未发现局域网地址，手机可能无法访问，请确认已连接 WiFi。\n".utf8))
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
                print("同一 WiFi 下扫码访问 · 按 Ctrl-C 停止分享")
            }
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data("启动失败: \(error)\n".utf8))
            exit(1)
        }
        RunLoop.main.run()
        exit(0)
    }

    // 路径集合 → 分享形态：单项判文件/文件夹，多项走虚拟根。
    private static func makeShare(_ urls: [URL]) -> FileServer.Share {
        if urls.count > 1 { return .multiple(FileServer.Share.makeItems(urls)) }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir)
        return isDir.boolValue ? .directory(urls[0]) : .file(urls[0])
    }
}
