import AppKit

// 命令行模式（`localshare a.html b.pdf`）：解析 argv 分流三种动作——
//   默认       把路径转发给 GUI app（已运行则复用实例热切换，未运行则拉起），命令立即返回
//   --headless 不开窗口，本进程前台起服务，打印链接 + 终端二维码，Ctrl-C 停止
//   --help / --version
// 判定规则刻意保守：Finder/LaunchServices 启动（无参数或仅 -psn_ 噪音）永不误入 CLI。
enum CLI {
    enum Mode {
        case open([URL])                        // 唤起/复用 GUI 分享这些路径（空 = 仅唤起）
        case headless([URL], port: in_port_t?)  // 前台起服务，不开窗口
        case help
        case version
    }

    // 返回 nil = 非命令行调用，按普通 GUI 启动。
    static func parse(_ rawArgs: [String]) -> Mode? {
        // 经 symlink（/usr/local/bin/localshare）调用时 argv[0] 是链接名，作第二判据。
        let viaSymlink = rawArgs.first.map { ($0 as NSString).lastPathComponent == "localshare" } ?? false
        let args = Array(rawArgs.dropFirst())

        var paths: [String] = []
        var headless = false
        var port: in_port_t?
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--headless":
                headless = true
            case "--port":
                i += 1
                guard i < args.count, let n = Int(args[i]), (1...65535).contains(n) else {
                    fail("--port 需要 1–65535 的端口号")
                }
                port = in_port_t(n)
            case "--help", "-h":
                return .help
            case "--version":
                return .version
            case "-NSDocumentRevisionsDebugMode":
                i += 1 // Xcode 调试噪音：连同其值一起跳过
            default:
                if a.hasPrefix("-psn_") { break } // 旧 LaunchServices 进程序号，忽略
                if a.hasPrefix("-") {
                    // 未知选项：明确的 CLI 调用就报错；否则视为 AppKit 噪音，按 GUI 启动。
                    if viaSymlink { fail("未知选项 \(a)") }
                    return nil
                }
                paths.append(a)
            }
            i += 1
        }

        if headless {
            if paths.isEmpty { fail("--headless 需要至少一个文件或文件夹路径") }
            return .headless(resolve(paths), port: port)
        }
        if port != nil { fail("--port 仅在 --headless 模式下有效") }
        if !paths.isEmpty { return .open(resolve(paths)) }
        if viaSymlink { return .open([]) } // `localshare` 不带参数：只唤起窗口
        return nil
    }

    static func run(_ mode: Mode) -> Never {
        switch mode {
        case .help:
            print(usage)
            exit(0)
        case .version:
            let info = hostAppURL().flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist")) }
            print(info?["CFBundleShortVersionString"] as? String ?? "dev")
            exit(0)
        case .headless(let urls, let port):
            // 默认回退链与 GUI 的 fallbackPorts 同源；不读 UserDefaults——经 symlink 启动时
            // bundle 解析不可靠。Optional 在这里展开（勿下移，见 runForeground 的编译器坑注释）。
            var prefer: [in_port_t] = [8080, 8000, 8888, 9000]
            if let port { prefer = [port] }
            HeadlessServer.runForeground(urls: urls, preferredPorts: prefer)
            exit(0)
        case .open(let urls):
            forwardToGUI(urls)
        }
    }

    // MARK: - 转发 GUI

    // 把路径交给 GUI app 打开：NSWorkspace 显式指定目标 app（无需声明文档类型），
    // 已运行的实例默认被复用、收到 open 事件热切换。本进程只等回调，不碰 NSApplication
    // （否则 Dock 会闪出第二个图标）。
    private static func forwardToGUI(_ urls: [URL]) -> Never {
        guard let app = hostAppURL() else {
            die("未找到 LocalShare.app，请先把它放进「应用程序」文件夹。")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        let done: (NSRunningApplication?, Error?) -> Void = { _, error in
            if let error { die("唤起 LocalShare 失败：\(error.localizedDescription)") }
            exit(0)
        }
        if urls.isEmpty {
            NSWorkspace.shared.openApplication(at: app, configuration: config, completionHandler: done)
        } else {
            NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: config, completionHandler: done)
        }
        RunLoop.main.run() // 等回调（回调里 exit）
        exit(0)
    }

    // 本进程真实所在的 .app。不能用 Bundle.main——经 symlink 启动时它可能按链接路径解析；
    // 这里自取可执行文件路径、解掉 symlink，再上溯 Contents/MacOS 两级。
    // 裸二进制（swift run / .build）不在 .app 内时，回退查询系统里已安装的 app。
    private static func hostAppURL() -> URL? {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        _NSGetExecutablePath(&buf, &size)
        let exec = URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath()
        let app = exec.deletingLastPathComponent()   // MacOS/
            .deletingLastPathComponent()             // Contents/
            .deletingLastPathComponent()             // .app
        if app.pathExtension == "app" { return app }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "live.ezze.localshare")
    }

    // MARK: - 路径与出错

    // 相对路径按 cwd 解析；任一路径不存在即整体报错退出，避免静默分享了一半。
    private static func resolve(_ paths: [String]) -> [URL] {
        let urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
        for url in urls where !FileManager.default.fileExists(atPath: url.path) {
            die("路径不存在：\(url.path)")
        }
        return urls
    }

    private static let usage = """
    用法：localshare [选项] <路径> …

      localshare a.html b.pdf       在 LocalShare 窗口里分享这些文件
      localshare --headless ./dir   不开窗口，在终端打印链接和二维码

    选项：
      --headless     前台运行，不打开窗口（Ctrl-C 停止）
      --port <端口>  headless 模式的监听端口（默认 8080，占用时自动回退）
      --version      打印版本号
      -h, --help     打印本帮助
    """

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n\n\(usage)\n".utf8))
        exit(2)
    }

    private static func die(_ message: String) -> Never {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        exit(1)
    }
}
