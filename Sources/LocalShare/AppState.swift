import AppKit
import SwiftUI

// 全局状态：当前分享对象（文件夹或单个文件）、服务运行态、网络接口候选、二维码 URL、
// 监听端口配置、最近分享历史、屏幕路由、权限（当前恒只读）。
// 负责：选目录/选文件、启停服务、端口配置 + 应用（重启服务）、记住上次分享并自动启动。
@MainActor
final class AppState: ObservableObject {
    enum Screen { case share, settings, history }
    enum AppearancePref: String { case system, light, dark }

    // 设计默认窗口尺寸（票据风竖窗，设计稿 400×720）。供 App 的 .defaultSize 与
    // 「恢复默认尺寸」共用同一处真相，避免两边各写一份数字漂移。
    static let defaultWindowWidth: CGFloat = 410
    static let defaultWindowHeight: CGFloat = 720

    @Published var sharedItems: [URL] = []   // 当前分享的项：0=空、1=单项、N=多选
    @Published var sharedIsFile = false   // 仅单项有意义：true=单个文件，false=单个文件夹
    @Published var sharedDetail: String?  // 人类可读元数据：文件→大小，文件夹/多选→项数
    @Published var isRunning = false
    @Published var port: in_port_t = 0    // 实际绑定端口（可能因占用回退而异于 configuredPort）
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface?
    @Published var localHost: String?
    @Published var lastError: String?
    @Published var viewerCount = 0        // 最近 45s 内活跃的访客设备数（FileServer 在线感知）

    @Published var permission = Permission()        // v1 恒只读；保留以驱动全局措辞
    @Published var configuredPort: in_port_t = 8080 // 用户期望端口（设置页可改，持久化）
    @Published var recents: [RecentShare] = []      // 最近分享（持久化）
    @Published var screen: Screen = .share          // 屏幕路由（分享 / 设置 / 历史）
    @Published var appearance: AppearancePref = .system  // 外观：跟随系统 / 浅色 / 深色（持久化）
    @Published var showRecents = true               // 主界面是否展示「最近分享」模块（持久化）
    @Published var cliStatus: CLIInstaller.Status = .notInstalled  // 命令行工具安装状态

    // GUI 进程仅构造一次，init 末尾自登记；AppDelegate 的 open 事件回调经它触达状态。
    static private(set) var shared: AppState?

    let token = Token.generate()
    private var server: FileServer?
    private var viewerTimer: Timer?

    private let sharedDefaultsKey = "lastFolderPath"   // 旧版单值键（迁移回退用，新写入走 sharedPathsKey）
    private let sharedPathsKey = "lastSharedPaths"      // 当前分享的项路径数组（支持多选）
    private let portKey = "configuredPort"
    private let recentsKey = "recentShares"
    private let appearanceKey = "appearancePref"
    private let showRecentsKey = "showRecentShares"
    // 配置端口优先，其余作回退（8080 列入回退以防配置端口占用）。
    private let fallbackPorts: [in_port_t] = [8000, 8888, 9000, 8080]

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: portKey)
        if (1024...65535).contains(savedPort) { configuredPort = in_port_t(savedPort) }
        if let a = UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppearancePref.init) { appearance = a }
        // bool(forKey:) 对未写入的键返回 false，会把默认「展示」误判成关闭，故先探键存在性。
        if UserDefaults.standard.object(forKey: showRecentsKey) != nil {
            showRecents = UserDefaults.standard.bool(forKey: showRecentsKey)
        }
        loadRecents()
        refreshNetwork()
        // 恢复上次分享对象并自动启动，让同事开 app 就能看到二维码。
        // 多选存为路径数组（新键）；读不到再回退旧单值键（迁移）。缺失的项自动剔除，剩 ≥1 即恢复。
        var restorePaths = UserDefaults.standard.stringArray(forKey: sharedPathsKey)
            ?? UserDefaults.standard.string(forKey: sharedDefaultsKey).map { [$0] }
            ?? []
        restorePaths = restorePaths.filter { FileManager.default.fileExists(atPath: $0) }
        if !restorePaths.isEmpty {
            sharedItems = restorePaths.map { URL(fileURLWithPath: $0) }
            updateSharedIsFile()
            describeShared()
            start()
        }
        AppState.shared = self
        // 消费早到的 open 事件（CLI 冷启动时可能先于本 init 到达），覆盖上面恢复的旧分享。
        if !AppDelegate.pendingOpenURLs.isEmpty {
            let urls = AppDelegate.pendingOpenURLs
            AppDelegate.pendingOpenURLs = []
            setShared(urls)
        }
    }

    // MARK: - 选择态派生

    var isEmpty: Bool { sharedItems.isEmpty }
    var isMultiple: Bool { sharedItems.count > 1 }
    var sharedURL: URL? { sharedItems.first }   // 单项便利访问；UI 仅在单项时使用
    var currentSharePaths: Set<String> { Set(sharedItems.map(\.path)) }

    // MARK: - 派生 URL / 二维码

    // 文件夹/多选模式 → 根地址；单文件模式 → 直链该文件（路径仅供浏览器显示文件名/扩展名）。
    private func makeURL(host: String) -> String {
        let q = "?t=\(token)"
        if sharedIsFile, let name = sharedItems.first?.lastPathComponent,
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
        if isMultiple { return "\(ip):\(port)/" }
        if sharedIsFile, let name = sharedItems.first?.lastPathComponent {
            return "\(ip):\(port)/\(name)"
        }
        let folder = sharedItems.first?.lastPathComponent ?? ""
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
    func pickAny()    { pick(files: true, directories: true, message: "选择文件或文件夹，可多选") }

    private func pick(files: Bool, directories: Bool, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true   // 允许一次选多个文件/目录
        panel.prompt = "分享"
        panel.message = message
        if panel.runModal() == .OK, !panel.urls.isEmpty { setShared(panel.urls) }
    }

    // 单项便利入口（拖入单个 / 重新分享单条历史）转调数组版。
    func setShared(_ url: URL) { setShared([url]) }

    func setShared(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        sharedItems = urls
        updateSharedIsFile()
        describeShared()
        UserDefaults.standard.set(urls.map(\.path), forKey: sharedPathsKey)
        UserDefaults.standard.removeObject(forKey: sharedDefaultsKey)   // 清理旧单值键
        recordRecent()
        screen = .share
        if isRunning {
            server?.share = currentShare   // 运行中只换分享对象，不重启（token/cookie 保持有效）
        } else {
            start()
        }
    }

    // 仅单项时判定文件/文件夹；多选时 sharedIsFile 无意义、置 false。
    private func updateSharedIsFile() {
        guard sharedItems.count == 1 else { sharedIsFile = false; return }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: sharedItems[0].path, isDirectory: &isDir)
        sharedIsFile = !isDir.boolValue
    }

    // 计算分享对象元数据：单文件→格式化大小；文件夹→顶层可见项数；多选→项数（口径同列表页）。
    private func describeShared() {
        guard let first = sharedItems.first else { sharedDetail = nil; return }
        if isMultiple {
            sharedDetail = "\(sharedItems.count) 项"
        } else if sharedIsFile {
            let bytes = (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sharedDetail = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: first, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            sharedDetail = "\(entries.count) 项"
        }
    }

    private var currentShare: FileServer.Share {
        switch sharedItems.count {
        case 0:  return .directory(URL(fileURLWithPath: NSTemporaryDirectory()))
        case 1:  return sharedIsFile ? .file(sharedItems[0]) : .directory(sharedItems[0])
        default: return .multiple(FileServer.Share.makeItems(sharedItems))
        }
    }

    // MARK: - 启停 / 端口

    func start() {
        guard !sharedItems.isEmpty else { return }
        refreshNetwork()
        let fs = FileServer(share: currentShare, token: token)
        do {
            var prefer = [configuredPort]
            prefer += fallbackPorts.filter { $0 != configuredPort }
            port = try fs.start(preferredPorts: prefer)
            server = fs
            isRunning = true
            lastError = nil
            startViewerPolling()
        } catch {
            lastError = "启动服务失败：\(error.localizedDescription)"
            isRunning = false
        }
    }

    func stop() {
        viewerTimer?.invalidate()
        viewerTimer = nil
        viewerCount = 0
        server?.stop()
        server = nil
        isRunning = false
        port = 0
    }

    // 轮询活跃访客数（activeViewers 锁内取快照，保持 server → state → view 的单向数据流）。
    private func startViewerPolling() {
        viewerTimer?.invalidate()
        viewerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.viewerCount = self.server?.activeViewers() ?? 0
            }
        }
    }

    func toggle() { isRunning ? stop() : start() }

    // 清除当前分享：停服务 + 清空选择，回到空状态（初始拖拽屏）。历史里仍保留该条，可一键重新分享。
    func clearShare() {
        stop()
        sharedItems = []
        sharedIsFile = false
        sharedDetail = nil
        UserDefaults.standard.removeObject(forKey: sharedPathsKey)
        UserDefaults.standard.removeObject(forKey: sharedDefaultsKey)
        screen = .share
    }

    // 应用新监听端口：持久化配置；运行中则重启服务（已分发链接需更新）。
    func applyPort(_ p: in_port_t) {
        configuredPort = p
        UserDefaults.standard.set(Int(p), forKey: portKey)
        guard isRunning, !sharedItems.isEmpty else { return }
        stop()
        start()
        if isRunning && port != p {
            lastError = "端口 \(p) 不可用，已自动改用 \(port)。"
        }
    }

    // MARK: - 最近分享 / 历史

    private func recordRecent() {
        guard !sharedItems.isEmpty else { return }
        let entry = RecentShare(paths: sharedItems.map(\.path), isFile: sharedIsFile,
                                detail: sharedDetail ?? "", date: Date())
        recents.removeAll { $0.id == entry.id }
        recents.insert(entry, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        saveRecents()
    }

    // 重新分享某条历史：等价于重新选中它。多选时过滤掉已不存在的项，全缺失才移除该条。
    func reshare(_ r: RecentShare) {
        let fm = FileManager.default
        let existing = r.paths.filter { fm.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            recents.removeAll { $0.id == r.id }; saveRecents()
            lastError = "该分享的文件已不存在，已从历史移除。"
            return
        }
        recents.removeAll { $0.id == r.id }   // 路径子集变化时，避免残留旧记录
        setShared(existing.map { URL(fileURLWithPath: $0) })
        if existing.count < r.paths.count {
            lastError = "有 \(r.paths.count - existing.count) 项已不存在，已自动跳过。"
        }
    }

    // 清空历史，但保留当前正在分享的那条。
    func clearRecents() {
        let cur = currentSharePaths
        if !cur.isEmpty { recents.removeAll { Set($0.paths) != cur } }
        else { recents.removeAll() }
        saveRecents()
    }

    // 是否为当前正在广播的那条历史。
    func isLive(_ r: RecentShare) -> Bool {
        isRunning && Set(r.paths) == currentSharePaths
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

    func setShowRecents(_ on: Bool) {
        showRecents = on
        UserDefaults.standard.set(on, forKey: showRecentsKey)
    }

    // 请求唤回主窗口（已关闭则重建）。openWindow 只能在活着的视图环境里拿，
    // 故发通知给常驻菜单栏的图标视图代为执行（见 App.swift 的 MenuBarIcon）。
    func showMainWindow() {
        NotificationCenter.default.post(name: .lsShowMainWindow, object: nil)
    }

    // MARK: - 命令行工具

    func refreshCLIStatus() {
        cliStatus = CLIInstaller.status()
    }

    // 安装/修复或卸载 symlink。提权对话框会阻塞，放后台线程跑完再回主线程刷状态。
    func installCLI()   { cliTask("安装") { try CLIInstaller.install() } }
    func uninstallCLI() { cliTask("卸载") { try CLIInstaller.uninstall() } }

    private func cliTask(_ verb: String, _ work: @escaping @Sendable () throws -> Void) {
        Task.detached { [weak self] in
            var failure: String?
            do {
                try work()
            } catch is CLIInstaller.Cancelled {
                // 用户在授权框点了取消，不当作错误
            } catch {
                failure = "\(verb)命令行工具失败：\(error.localizedDescription)"
            }
            await MainActor.run { [weak self, failure] in
                guard let self else { return }
                self.refreshCLIStatus()
                if let failure { self.lastError = failure }
            }
        }
    }

    // 把主窗口恢复到设计默认尺寸：锚定左上角不动（macOS 原点在左下，故顶随高变），带动画回弹。
    // 用 canBecomeMain 过滤掉弹层/面板（popover、NSPanel 均为 false），单窗口 app 只会命中主窗。
    func resetWindowSize() {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let target = NSSize(width: AppState.defaultWindowWidth, height: AppState.defaultWindowHeight)
        var frame = window.frame
        frame.origin.y = frame.maxY - target.height
        frame.size = target
        window.setFrame(frame, display: true, animate: true)
    }
}

// 一条最近分享记录（持久化到 UserDefaults）。paths 支持多选（1=单项、N=多选）。
struct RecentShare: Codable, Identifiable, Equatable {
    let paths: [String]
    let isFile: Bool       // 仅单项有意义
    let detail: String
    let date: Date

    var isMultiple: Bool { paths.count > 1 }
    var id: String { paths.joined(separator: "\n") }
    var name: String {
        if isMultiple { return "\(paths.count) 个项目" }
        return paths.first.map { ($0 as NSString).lastPathComponent } ?? ""
    }
    // 多选：只要还有一项存在即可重新分享（reshare 时再剔除缺失项）。
    var exists: Bool {
        let fm = FileManager.default
        return paths.contains { fm.fileExists(atPath: $0) }
    }

    init(paths: [String], isFile: Bool, detail: String, date: Date) {
        self.paths = paths; self.isFile = isFile; self.detail = detail; self.date = date
    }

    // 兼容旧记录：旧版用单 `path` 字段，迁移为 `paths = [path]`。
    enum CodingKeys: String, CodingKey { case paths, path, isFile, detail, date }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let arr = try? c.decode([String].self, forKey: .paths) {
            paths = arr
        } else {
            paths = [try c.decode(String.self, forKey: .path)]
        }
        isFile = (try? c.decode(Bool.self, forKey: .isFile)) ?? false
        detail = (try? c.decode(String.self, forKey: .detail)) ?? ""
        date = (try? c.decode(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
    }
    // 显式 encode（CodingKeys 含迁移用的 .path，会阻断合成）：只写 paths 等当前字段。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(paths, forKey: .paths)
        try c.encode(isFile, forKey: .isFile)
        try c.encode(detail, forKey: .detail)
        try c.encode(date, forKey: .date)
    }
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
