import Foundation

// 无界面运行模式（LS_HEADLESS=1）：仅启动 FileServer 并阻塞，供测试/自动化使用。
// 通过环境变量配置：
//   LS_FOLDER   要服务的单个文件/文件夹（与 LS_FOLDERS 二选一）
//   LS_FOLDERS  多项：以 ':' 或换行分隔的多个路径（走多选虚拟根）
//   LS_TOKEN    访问令牌（选填，默认 testtoken）
//   LS_PORT     端口（选填，默认 8080）
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
        let share: FileServer.Share
        if urls.count > 1 {
            share = .multiple(FileServer.Share.makeItems(urls))
        } else {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: urls[0].path, isDirectory: &isDir)
            share = isDir.boolValue ? .directory(urls[0]) : .file(urls[0])
        }
        let server = FileServer(share: share, token: token)
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
}
