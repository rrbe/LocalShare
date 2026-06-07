import AppKit
import SwiftUI

// 全局状态：当前分享对象（文件夹或单个文件）、服务运行态、网络接口候选、二维码 URL、
// 监听端口配置、最近分享历史、屏幕路由、权限（当前恒只读）。
// 负责：选目录/选文件、启停服务、端口配置 + 应用（重启服务）、记住上次分享并自动启动。
@MainActor
final class AppState: ObservableObject {
    enum Screen { case share, settings, history }
    enum AppearancePref: String { case system, light, dark }

    @Published var sharedURL: URL?
    @Published var sharedIsFile = false   // true=分享单个文件，false=分享文件夹
    @Published var sharedDetail: String?  // 人类可读元数据：文件→大小，文件夹→顶层项数
    @Published var isRunning = false
    @Published var port: in_port_t = 0    // 实际绑定端口（可能因占用回退而异于 configuredPort）
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface?
    @Published var localHost: String?
    @Published var lastError: String?

    @Published var permission = Permission()        // v1 恒只读；保留以驱动全局措辞
    @Published var configuredPort: in_port_t = 8080 // 用户期望端口（设置页可改，持久化）
    @Published var recents: [RecentShare] = []      // 最近分享（持久化）
    @Published var screen: Screen = .share          // 屏幕路由（分享 / 设置 / 历史）
    @Published var appearance: AppearancePref = .system  // 外观：跟随系统 / 浅色 / 深色（持久化）

    let token = Token.generate()
    private var server: FileServer?

    private let sharedDefaultsKey = "lastFolderPath"   // 沿用旧键，存文件或文件夹路径
    private let portKey = "configuredPort"
    private let recentsKey = "recentShares"
    private let appearanceKey = "appearancePref"
    // 配置端口优先，其余作回退（8080 列入回退以防配置端口占用）。
    private let fallbackPorts: [in_port_t] = [8000, 8888, 9000, 8080]

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: portKey)
        if (1024...65535).contains(savedPort) { configuredPort = in_port_t(savedPort) }
        if let a = UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppearancePref.init) { appearance = a }
        loadRecents()
        refreshNetwork()
        // 恢复上次分享对象并自动启动，让同事开 app 就能看到二维码
        if let path = UserDefaults.standard.string(forKey: sharedDefaultsKey) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
                sharedURL = URL(fileURLWithPath: path)
                sharedIsFile = !isDir.boolValue
                describeShared()
                start()
            }
        }
    }

    // MARK: - 派生 URL / 二维码

    // 文件夹模式 → 根地址；单文件模式 → 直链该文件（路径仅供浏览器显示文件名/扩展名）。
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

    // 仅展示用的「主机:端口/尾部」短地址（隐去 token 与 http://，超长由 UI 中段省略）。
    var displayAddress: String? {
        guard isRunning, port != 0, let ip = selectedInterface?.ip else { return nil }
        if sharedIsFile, let name = sharedURL?.lastPathComponent {
            return "\(ip):\(port)/\(name)"
        }
        let folder = sharedURL?.lastPathComponent ?? ""
        return "\(ip):\(port)/\(folder)/"
    }

    var qrImage: NSImage? {
        guard let primaryURL else { return nil }
        return QRCode.image(for: primaryURL)
    }

    var hasNetwork: Bool { !interfaces.isEmpty }

    // MARK: - 网络

    func refreshNetwork() {
        interfaces = NetworkInfo.privateIPv4Interfaces()
        localHost = NetworkInfo.localHostName()
        if let sel = selectedInterface, interfaces.contains(sel) { return }
        selectedInterface = interfaces.first
    }

    // MARK: - 选择分享对象

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
        describeShared()
        UserDefaults.standard.set(url.path, forKey: sharedDefaultsKey)
        recordRecent()
        screen = .share
        if isRunning {
            server?.share = currentShare   // 运行中只换分享对象，不重启（token/cookie 保持有效）
        } else {
            start()
        }
    }

    // 计算分享对象元数据：单文件→格式化大小；文件夹→顶层可见项数（口径同列表页）。
    private func describeShared() {
        guard let url = sharedURL else { sharedDetail = nil; return }
        if sharedIsFile {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sharedDetail = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            sharedDetail = "\(entries.count) 项"
        }
    }

    private var currentShare: FileServer.Share {
        let url = sharedURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return sharedIsFile ? .file(url) : .directory(url)
    }

    // MARK: - 启停 / 端口

    func start() {
        guard sharedURL != nil else { return }
        refreshNetwork()
        let fs = FileServer(share: currentShare, token: token)
        do {
            var prefer = [configuredPort]
            prefer += fallbackPorts.filter { $0 != configuredPort }
            port = try fs.start(preferredPorts: prefer)
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

    // 清除当前分享：停服务 + 清空选择，回到空状态（初始拖拽屏）。历史里仍保留该条，可一键重新分享。
    func clearShare() {
        stop()
        sharedURL = nil
        sharedIsFile = false
        sharedDetail = nil
        UserDefaults.standard.removeObject(forKey: sharedDefaultsKey)
        screen = .share
    }

    // 应用新监听端口：持久化配置；运行中则重启服务（已分发链接需更新）。
    func applyPort(_ p: in_port_t) {
        configuredPort = p
        UserDefaults.standard.set(Int(p), forKey: portKey)
        guard isRunning, sharedURL != nil else { return }
        stop()
        start()
        if isRunning && port != p {
            lastError = "端口 \(p) 不可用，已自动改用 \(port)。"
        }
    }

    // MARK: - 最近分享 / 历史

    private func recordRecent() {
        guard let url = sharedURL else { return }
        let entry = RecentShare(path: url.path, isFile: sharedIsFile,
                                detail: sharedDetail ?? "", date: Date())
        recents.removeAll { $0.path == entry.path }
        recents.insert(entry, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        saveRecents()
    }

    // 重新分享某条历史：等价于重新选中它。
    func reshare(_ r: RecentShare) {
        guard r.exists else {
            recents.removeAll { $0.path == r.path }; saveRecents()
            lastError = "该文件已不存在，已从历史移除。"
            return
        }
        setShared(URL(fileURLWithPath: r.path))
    }

    // 清空历史，但保留当前正在分享的那条。
    func clearRecents() {
        if let cur = sharedURL?.path { recents.removeAll { $0.path != cur } }
        else { recents.removeAll() }
        saveRecents()
    }

    // 是否为当前正在广播的那条历史。
    func isLive(_ r: RecentShare) -> Bool {
        isRunning && sharedURL?.path == r.path
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: recentsKey),
              let list = try? JSONDecoder().decode([RecentShare].self, from: data) else { return }
        recents = list
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: recentsKey)
        }
    }

    // MARK: - 路由

    func openSettings() { screen = .settings }
    func openHistory()  { screen = .history }
    func goShare()      { screen = .share }

    func setAppearance(_ a: AppearancePref) {
        appearance = a
        UserDefaults.standard.set(a.rawValue, forKey: appearanceKey)
    }
}

// 一条最近分享记录（持久化到 UserDefaults）。
struct RecentShare: Codable, Identifiable, Equatable {
    let path: String
    let isFile: Bool
    let detail: String
    let date: Date
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

// MARK: - 端口实时校验（DESIGN.md §6.3）

enum PortState { case ok, occupied, invalid }

struct PortCheck {
    let state: PortState
    let message: String
    let suggest: in_port_t?
}

// 输入即校验：空 / 越界 → invalid；命中常用占用端口 → occupied + 建议下一个可用；其余 → ok。
// 占用集合为启发式（与设计稿一致）；真正能否绑定以「应用」时实际 start 结果为准。
func validatePort(_ raw: String) -> PortCheck {
    let occupied: Set<Int> = [80, 443, 3000, 5000, 5432, 3306, 8000, 7890]
    let v = raw.trimmingCharacters(in: .whitespaces)
    guard !v.isEmpty else { return PortCheck(state: .invalid, message: "请输入端口号", suggest: nil) }
    guard let n = Int(v) else { return PortCheck(state: .invalid, message: "端口需为数字", suggest: nil) }
    if n < 1024  { return PortCheck(state: .invalid, message: "需 ≥ 1024 · 1023 以下为系统保留端口", suggest: nil) }
    if n > 65535 { return PortCheck(state: .invalid, message: "超出范围 · 端口最大为 65535", suggest: nil) }
    if occupied.contains(n) {
        var s = n + 1
        while occupied.contains(s) || s > 65535 { s = s > 65535 ? 1024 : s + 1 }
        return PortCheck(state: .occupied, message: "端口 \(v) 已被其他程序占用", suggest: in_port_t(s))
    }
    return PortCheck(state: .ok, message: "端口可用", suggest: nil)
}
