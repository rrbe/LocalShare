import AppKit
import SwiftUI

// 全局状态：当前文件夹、服务运行态、网络接口候选、二维码 URL。
// 负责：选目录、启停服务、端口自动选择、记住上次文件夹并自动启动。
@MainActor
final class AppState: ObservableObject {
    @Published var folderURL: URL?
    @Published var isRunning = false
    @Published var port: in_port_t = 0
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface?
    @Published var localHost: String?
    @Published var lastError: String?

    let token = Token.generate()
    private var server: FileServer?

    private let folderDefaultsKey = "lastFolderPath"
    private let preferredPorts: [in_port_t] = [8080, 8000, 8888, 9000]

    init() {
        refreshNetwork()
        // 恢复上次文件夹并自动启动，让同事开 app 就能看到二维码
        if let path = UserDefaults.standard.string(forKey: folderDefaultsKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) {
                folderURL = url
                start()
            }
        }
    }

    // MARK: - 派生 URL / 二维码

    var primaryURL: String? {
        guard isRunning, port != 0, let ip = selectedInterface?.ip else { return nil }
        return "http://\(ip):\(port)/?t=\(token)"
    }

    var localURL: String? {
        guard isRunning, port != 0, let host = localHost else { return nil }
        return "http://\(host):\(port)/?t=\(token)"
    }

    var qrImage: NSImage? {
        guard let primaryURL else { return nil }
        return QRCode.image(for: primaryURL)
    }

    var hasNetwork: Bool { !interfaces.isEmpty }

    // MARK: - 操作

    func refreshNetwork() {
        interfaces = NetworkInfo.privateIPv4Interfaces()
        localHost = NetworkInfo.localHostName()
        if let sel = selectedInterface, interfaces.contains(sel) { return }
        selectedInterface = interfaces.first
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择要分享给手机访问的文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            setFolder(url)
        }
    }

    func setFolder(_ url: URL) {
        folderURL = url
        UserDefaults.standard.set(url.path, forKey: folderDefaultsKey)
        if isRunning {
            server?.root = url // 运行中只换根目录，不重启（token/cookie 保持有效）
        } else {
            start()
        }
    }

    func start() {
        guard let folderURL else { return }
        refreshNetwork()
        let fs = FileServer(root: folderURL, token: token)
        do {
            port = try fs.start(preferredPorts: preferredPorts)
            server = fs
            isRunning = true
            lastError = nil
        } catch {
            lastError = "启动服务失败：\(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isRunning = false
        port = 0
    }

    func toggle() { isRunning ? stop() : start() }
}
