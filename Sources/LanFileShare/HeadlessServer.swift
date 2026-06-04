import Foundation

// 无界面运行模式（LFS_HEADLESS=1）：仅启动 FileServer 并阻塞，供测试/自动化使用。
// 通过环境变量配置：
//   LFS_FOLDER  要服务的文件夹（必填）
//   LFS_TOKEN   访问令牌（选填，默认 testtoken）
//   LFS_PORT    端口（选填，默认 8080）
enum HeadlessServer {
    static func run() {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["LFS_FOLDER"] else {
            FileHandle.standardError.write(Data("LFS_FOLDER 未设置\n".utf8))
            exit(2)
        }
        let token = env["LFS_TOKEN"] ?? "testtoken"
        let port = in_port_t(env["LFS_PORT"].flatMap { Int($0) } ?? 8080)

        let server = FileServer(root: URL(fileURLWithPath: folder, isDirectory: true), token: token)
        do {
            let bound = try server.start(preferredPorts: [port])
            print("LFS_URL http://127.0.0.1:\(bound)/?t=\(token)")
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data("启动失败: \(error)\n".utf8))
            exit(1)
        }
        RunLoop.main.run()
    }
}
