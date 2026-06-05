import AppKit
import SwiftUI

// 全局状态：当前分享对象（文件夹或单个文件）、服务运行态、网络接口候选、二维码 URL。
// 负责：选目录/选文件、启停服务、端口自动选择、记住上次分享并自动启动。
@MainActor
final class AppState: ObservableObject {
    @Published var sharedURL: URL?
    @Published var sharedIsFile = false   // true=分享单个文件，false=分享文件夹
    @Published var isRunning = false
    @Published var port: in_port_t = 0
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface?
    @Published var localHost: String?
    @Published var lastError: String?

    let token = Token.generate()
    private var server: FileServer?

    private let sharedDefaultsKey = "lastFolderPath"   // 沿用旧键，存文件或文件夹路径
    private let preferredPorts: [in_port_t] = [8080, 8000, 8888, 9000]

    init() {
        refreshNetwork()
        // 恢复上次分享对象并自动启动，让同事开 app 就能看到二维码
        if let path = UserDefaults.standard.string(forKey: sharedDefaultsKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                sharedURL = URL(fileURLWithPath: path)
                sharedIsFile = !isDir.boolValue
                start()
            }
        }
    }

    // MARK: - 派生 URL / 二维码

    // 文件夹模式 → 根地址；单文件模式 → 直链该文件（路径仅供浏览器显示文件名/扩展名，
    // 服务端单文件模式下任何路径都只发这一个文件）。
    private func makeURL(host: String) -> String {
        let q = "?t=\(token)"
        if sharedIsFile, let name = sharedURL?.lastPathComponent,
           let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) {
            return "http://\(host):\(port)/\(enc)\(q)"
        }
        return "http://\(host):\(port)/\(q)"
    }

    var primaryURL: String? {
        guard isRunning, port != 0, let ip = selectedInterface?.ip else { return nil }
        return makeURL(host: ip)
    }

    var localURL: String? {
        guard isRunning, port != 0, let host = localHost else { return nil }
        return makeURL(host: host)
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

    func pickFolder() { pick(files: false, directories: true, message: "选择要广播到局域网的文件夹") }
    func pickFile()   { pick(files: true, directories: false, message: "选择要单独分享的文件（扫码直接打开它）") }
    func pickAny()    { pick(files: true, directories: true, message: "选择文件夹，或单个文件") }

    private func pick(files: Bool, directories: Bool, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = false
        panel.prompt = "分享"
        panel.message = message
        if panel.runModal() == .OK, let url = panel.url { setShared(url) }
    }

    func setShared(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        sharedURL = url
        sharedIsFile = !isDir.boolValue
        UserDefaults.standard.set(url.path, forKey: sharedDefaultsKey)
        if isRunning {
            server?.share = currentShare   // 运行中只换分享对象，不重启（token/cookie 保持有效）
        } else {
            start()
        }
    }

    // 由 sharedURL + sharedIsFile 推出服务端的分享配置。仅在 sharedURL 非空时取用。
    private var currentShare: FileServer.Share {
        let url = sharedURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return sharedIsFile ? .file(url) : .directory(url)
    }

    func start() {
        guard sharedURL != nil else { return }
        refreshNetwork()
        let fs = FileServer(share: currentShare, token: token)
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
