import AppKit

// /usr/local/bin/localshare → .app 内主二进制 的 symlink 安装与状态检测。
// 非沙盒 app：先直接建链；目录不可写（或不存在且建不了）时经 osascript 管理员授权重试。
// dyld 解析 @executable_path 前会对主二进制做 realpath，故经 symlink 启动时
// 包内 Sparkle.framework 照常找得到（同 Sublime Text `subl` 的机制）。
enum CLIInstaller {
    static let linkPath = "/usr/local/bin/localshare"

    enum Status: Equatable {
        case notInstalled
        case installed               // 链接指向当前 app 内二进制
        case stale(current: String)  // 链接存在但指向别处（app 移动过 / 旧版本残留）
    }

    struct Cancelled: Error {}       // 用户在授权框点了取消

    // 当前进程的主二进制路径。GUI 永远由真实 .app 路径拉起（不经 symlink），Bundle.main 可靠。
    // 仅在确实跑在 .app 包内时返回——裸二进制（swift run / .build）装出去的链接指向构建产物，
    // 路径易失效且 CLI 无法据此定位 .app，设置面板靠返回 nil 收起「安装」按钮（状态/卸载照常）。
    static func binaryPath() -> String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.executableURL?.resolvingSymlinksInPath().path
    }

    static func status() -> Status {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return .notInstalled
        }
        // 两侧都解干净再比对——/usr/local 本身也可能是链接。
        let resolved = URL(fileURLWithPath: dest).resolvingSymlinksInPath().path
        return resolved == binaryPath() ? .installed : .stale(current: dest)
    }

    static func install() throws {
        guard let bin = binaryPath() else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: "/usr/local/bin", withIntermediateDirectories: true)
            try? fm.removeItem(atPath: linkPath)
            try fm.createSymbolicLink(atPath: linkPath, withDestinationPath: bin)
        } catch {
            try runPrivileged("mkdir -p /usr/local/bin && ln -sfn \(shellQuote(bin)) \(shellQuote(linkPath))")
        }
    }

    // 卸载只删 symlink：路径上若是同名真实文件（非我们装的），不动它。
    static func uninstall() throws {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: linkPath)) != nil else { return }
        do {
            try fm.removeItem(atPath: linkPath)
        } catch {
            try runPrivileged("rm -f \(shellQuote(linkPath))")
        }
    }

    // shell 单引号包裹（内部 ' → '\''），供拼入提权命令。
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // 经 osascript 管理员授权执行 shell 命令；整条命令再按 AppleScript 字符串转义一层。
    private static func runPrivileged(_ cmd: String) throws {
        let escaped = cmd
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let stderr = Pipe()
        p.standardError = stderr
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return }
        let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if msg.contains("-128") { throw Cancelled() }  // User canceled.
        throw NSError(domain: "LocalShare.CLIInstaller", code: Int(p.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines)])
    }
}
