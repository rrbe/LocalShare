import AppKit
import SwiftUI

// 全局状态：当前分享对象（文件夹或单个文件）、服务运行态、网络接口候选、二维码 URL、
// 监听端口配置、最近分享历史、屏幕路由、权限（读取常开，上传可切换）。
// 负责：选目录/选文件、启停服务、端口配置 + 应用（重启服务）、把分享记入最近分享（冷启动不自动重播）。
@MainActor
final class AppState: ObservableObject {
    // 屏幕路由。.share = 功能主页（launchpad：拖拽分享入口 + 传递文本入口 + 最近分享）；
    // .file = 文件二维码票据（二级页，带返回）。文本/设置/历史各为带返回的二级页。
    enum Screen { case share, file, text, settings, history }
    enum AppearancePref: String { case system, light, dark }

    // 设计默认窗口尺寸（票据风竖窗，设计稿 400×720）。供 App 的 .defaultSize 与
    // 「恢复默认尺寸」共用同一处真相，避免两边各写一份数字漂移。
    static let defaultWindowWidth: CGFloat = 450
    static let defaultWindowHeight: CGFloat = 720

    @Published var sharedItems: [URL] = []   // 当前分享的项：0=空、1=单项、N=多选
    @Published var sharedIsFile = false   // 仅单项有意义：true=单个文件，false=单个文件夹
    @Published var sharedDetail: String?  // 人类可读元数据：文件→大小，文件夹/多选→项数
    @Published var sharedText: String?    // 当前广播的一段文本（nil=未分享文本）；与 sharedItems 正交
    @Published var textDraft = ""         // 文本编辑器草稿（重启回填、再次编辑用）；与 sharedText 解耦
    @Published var isRunning = false
    @Published var port: in_port_t = 0    // 实际绑定端口（可能因占用回退而异于 configuredPort）
    @Published var interfaces: [NetworkInterface] = []
    @Published var selectedInterface: NetworkInterface?
    @Published var localHost: String?
    @Published var lastError: String?
    @Published var viewerCount = 0        // 最近 45s 内活跃的访客设备数（FileServer 在线感知）
    @Published var viewers: [ViewerInfo] = []   // 在线访客明细（设备名 / 完整 IP），最近活跃在前
    @Published var received: [URL] = []   // 本次分享期间访客上传的文件（新→旧，最多留 5 条）
    @Published var receivedTexts: [ReceivedText] = []   // 手机投递来的文本（收件箱，新→旧，最多 100 条挤旧）
    @Published var unreadReceived = 0     // 收件箱未读条数（角标）；用户查看/复制即清零

    @Published var permission = Permission()        // read 常开；add 可切（仅单文件夹分享）；edit/del 未开放
    @Published var configuredPort: in_port_t = 8080 // 用户期望端口（设置页可改，持久化）
    @Published var bindSelectedOnly = false         // 仅绑选中网卡（默认关=绑全部接口，持久化）
    @Published var recents: [RecentShare] = []      // 最近分享（持久化）
    @Published var screen: Screen = .share          // 屏幕路由（默认落功能主页）
    @Published var appearance: AppearancePref = .system  // 外观：跟随系统 / 浅色 / 深色（持久化）
    @Published var langPref: LangPref = .system     // 语言：跟随系统 / 中文 / English（持久化）
    @Published var showRecents = true               // 主界面是否展示「最近分享」模块（持久化）
    @Published var persistText = false              // 「记住分享的文本」开关（默认关，持久化）
    @Published var textInboxEnabled = false         // 「允许收文本」闸门（默认关，持久化；不限分享形态）
    @Published var persistReceivedText = false      // 「记住收到的文本」（默认关，持久化）
    @Published var cliStatus: CLIInstaller.Status = .notInstalled  // 命令行工具安装状态

    // GUI 进程仅构造一次，init 末尾自登记；AppDelegate 的 open 事件回调经它触达状态。
    static private(set) var shared: AppState?

    // 分享访问令牌：随每次「分享」动作轮换（setShared / stop），不随 app 进程长存——
    // 换分享或停止即作废旧链接、旧 cookie 与拍走的旧二维码，权限不跨分享延续。
    @Published private(set) var token = Token.generate()
    private var server: FileServer?
    private var viewerTimer: Timer?

    private let portKey = "configuredPort"
    private let bindSelectedOnlyKey = "bindSelectedOnly"
    private let recentsKey = "recentShares"
    private let appearanceKey = "appearancePref"
    private let langPrefKey = "languagePref"
    private let showRecentsKey = "showRecentShares"
    private let persistTextKey = "persistSharedText"   // 是否记住分享的文本（默认关）
    private let sharedTextKey = "lastSharedText"        // 上次分享的文本（仅 persistText 开时写入）
    private let textInboxKey = "textInboxEnabled"       // 收件箱闸门（默认关）
    private let persistReceivedKey = "persistReceivedText"  // 是否记住收到的文本（默认关）
    private let receivedTextsKey = "receivedTexts"      // 收件箱内容（仅 persistReceivedText 开时写入）
    // 配置端口优先，其余作回退（8080 列入回退以防配置端口占用）。
    private let fallbackPorts: [in_port_t] = [8000, 8888, 9000, 8080]

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: portKey)
        if (1024...65535).contains(savedPort) { configuredPort = in_port_t(savedPort) }
        bindSelectedOnly = UserDefaults.standard.bool(forKey: bindSelectedOnlyKey)   // 未写入默认 false
        if let a = UserDefaults.standard.string(forKey: appearanceKey).flatMap(AppearancePref.init) { appearance = a }
        if let l = UserDefaults.standard.string(forKey: langPrefKey).flatMap(LangPref.init) { langPref = l }
        Lang.current = Lang.resolve(langPref)   // 同步快照，供菜单/命令构造处读取
        // bool(forKey:) 对未写入的键返回 false，会把默认「展示」误判成关闭，故先探键存在性。
        if UserDefaults.standard.object(forKey: showRecentsKey) != nil {
            showRecents = UserDefaults.standard.bool(forKey: showRecentsKey)
        }
        persistText = UserDefaults.standard.bool(forKey: persistTextKey)   // 未写入默认 false
        // 记住分享文本时回填草稿（编辑器预填上次内容），但**不**放进 sharedText、不自动广播——
        // 文本常是密码/口令，自动重新广播会在 LAN 上悄悄重现，故重启需用户手动「分享」(见 docs/ARCHITECTURE.md)。
        if persistText, let t = UserDefaults.standard.string(forKey: sharedTextKey), !t.isEmpty {
            textDraft = t
        }
        // 收件箱闸门与（可选）持久化的收件箱内容。收件箱开着即便没分享任何内容也要自动起服务（见下）。
        textInboxEnabled = UserDefaults.standard.bool(forKey: textInboxKey)   // 未写入默认 false
        persistReceivedText = UserDefaults.standard.bool(forKey: persistReceivedKey)
        if persistReceivedText { loadReceivedTexts() }
        loadRecents()
        refreshNetwork()
        // 冷启动**不**自动重播上次文件分享：开 app 就把某文件夹悄悄端上 LAN 是隐患（同文本「重启不自动
        // 重播」的安全姿态，见上）。上次分享留在「最近分享」一键重发。只关窗口不退出时进程与服务都续活，
        // 唤回窗口即回到原状——那条路径不经过本 init，故此处只管「真退出后重开」这一冷启动。
        // 收件箱是用户显式开的闸门，仍自动起服务。
        if isServing { start() }
        // 启动落地屏：默认功能主页；收件箱开着则落传递文本页（接收已就绪一眼可见）。
        // 冷启动不恢复分享，故此处 sharedItems 必空、无须再判（CLI open 的 setShared 在其后才跑、会改落 .file）。
        if textInboxEnabled { screen = .text }
        AppState.shared = self
        // 消费早到的 open 事件（CLI 冷启动时可能先于本 init 到达）：有则据此分享、落文件票据。
        if !AppDelegate.pendingOpenURLs.isEmpty {
            let urls = AppDelegate.pendingOpenURLs
            AppDelegate.pendingOpenURLs = []
            setShared(urls)
        }
    }

    // MARK: - 选择态派生

    // 「空」= 既无文件项也无文本（决定起服务/二维码/空状态屏）。文本可独立存在，故不能只看 sharedItems。
    var isEmpty: Bool { sharedItems.isEmpty && !hasText }
    var isMultiple: Bool { sharedItems.count > 1 }
    var hasText: Bool { !(sharedText?.isEmpty ?? true) }
    var isTextOnly: Bool { sharedItems.isEmpty && hasText }   // 只分享文本、无文件
    // 有任何理由起服务：有分享内容（文件/文本），或收件箱开着（即便什么都没分享也要服务 /ls/send）。
    var isServing: Bool { !isEmpty || textInboxEnabled }
    // 只收文本、没分享任何内容：二维码直指发送页 /ls/send，主界面出收件模式票据。
    var isReceiveOnly: Bool { isEmpty && textInboxEnabled }
    var sharedURL: URL? { sharedItems.first }   // 单项便利访问；UI 仅在单项时使用
    var currentSharePaths: Set<String> { Set(sharedItems.map(\.path)) }

    // MARK: - 派生 URL / 二维码

    // 文件夹/多选模式 → 根地址；单文件模式 → 直链该文件（路径仅供浏览器显示文件名/扩展名）。
    private func makeURL(host: String) -> String {
        let q = "?t=\(token)"
        // 传递文本（收/发合一）：二维码恒指 /ls/text——这一页既显示电脑共享的文本（可读可复制），
        // 又在「允许手机发回来」开着时挂出发送框；只收文本时它退化成纯发送页。扫一次，双向都在这。
        if isTextOnly || isReceiveOnly { return "http://\(host):\(port)/ls/text\(q)" }
        // 单文件直链该文件（文本与文件共存时走虚拟根，不直链，故附带 !hasText）。
        if sharedIsFile, !hasText, let name = sharedItems.first?.lastPathComponent,
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

    // MARK: - 网络

    func refreshNetwork() {
        interfaces = NetworkInfo.privateIPv4Interfaces()
        localHost = NetworkInfo.localHostName()
        if let sel = selectedInterface, interfaces.contains(sel) { return }
        selectedInterface = interfaces.first
    }

    // MARK: - 选择分享对象

    func pickFolder() { pick(files: false, directories: true, message: L.pickFolderMsg(lang)) }
    func pickFile()   { pick(files: true, directories: false, message: L.pickFileMsg(lang)) }
    func pickAny()    { pick(files: true, directories: true, message: L.pickAnyMsg(lang)) }

    private func pick(files: Bool, directories: Bool, message: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = directories
        panel.allowsMultipleSelection = true   // 允许一次选多个文件/目录
        panel.prompt = L.sharePrompt(lang)
        panel.message = message
        if panel.runModal() == .OK, !panel.urls.isEmpty { setShared(panel.urls) }
    }

    // 单项便利入口（拖入单个 / 重新分享单条历史）转调数组版。
    func setShared(_ url: URL) { setShared([url]) }

    func setShared(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        token = Token.generate()   // 换分享即换钥匙：上一次分享的链接/cookie/二维码全部作废
        sharedItems = urls
        updateSharedIsFile()
        describeShared()
        resetUpload()   // 换分享内容即回到只读（安全默认），收件提示一并清空
        recordRecent()
        screen = .file   // 进文件票据二级页（带返回）；冷启动不恢复，故只需记入最近分享
        if isRunning { pushToServer() }   // 运行中不重启（端口不变）
        else { start() }
    }

    // 运行中把当前分享态推给 server（不重启、端口不变）。顺序不变式：先写 token 再推内容(sharedText / share)
    // ——换分享(setShared)时新钥匙必须先于新内容落地，杜绝旧 token 读到新分享的瞬间窗口（见 CLAUDE.md 线程模型）。
    // setShared（换钥匙）与 setSharedText（不换钥匙，仅会话内更新文本）共用此推送，故恒按此序写。
    private func pushToServer() {
        server?.token = token
        server?.sharedText = hasText ? sharedText : nil
        server?.textInboxEnabled = textInboxEnabled
        server?.share = currentShare
    }

    // 分享 / 更新一段文本（Mac→手机）。token 的「会话」维度与分享文件一致：只在会话边界轮换
    //（setShared 换分享、stop/clearShare 结束），**编辑/更新文本本身不换 token**——正在看的手机刷新仍是
    // 同一把钥匙、无须重扫（会话内内容可随手迭代）；与文件共存时改文本更不会误伤文件分享的链接。
    // 传 nil/空白即撤下文本；若同时无文件、也没开接收则停服务（由 stop 轮换 token、那才真正作废链接）。
    // 文本与已分享的文件正交：设了文本不动文件、撤了文本也不动文件。
    func setSharedText(_ raw: String?) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText: String? = (trimmed?.isEmpty ?? true) ? nil : trimmed
        sharedText = newText
        textDraft = newText ?? ""
        describeShared()
        // 持久化：仅「记住分享的文本」开启且确有文本时写盘；撤下文本（newText==nil）或未开持久化一律抹掉——
        // 即「撤下即清」，杜绝用户明确撤下后磁盘仍残留旧口令、下次启动又被回填进编辑器。
        if persistText, let newText { UserDefaults.standard.set(newText, forKey: sharedTextKey) }
        else { UserDefaults.standard.removeObject(forKey: sharedTextKey) }
        // 仅纯文本分享记历史（文本条目，且仅 persistText 开时真正落库，见 recordRecent）；
        // 文本+文件时不调——否则「只改了文本」会把已有的文件条目刷到历史顶部、刷新时间戳。
        if isTextOnly { recordRecent() }
        // 纯文本场景（无文件）的文本动作进/留传递文本页；与文件共存时不抢走文件票据（仍在分享页就地编辑）。
        if sharedItems.isEmpty && (hasText || textInboxEnabled) { screen = .text }
        if isRunning {
            if isEmpty && !textInboxEnabled { stop() }   // 撤下文本、无文件、也没开接收 → 拆服务回初始
            else { pushToServer() }
        } else if isServing {
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
            sharedDetail = LStr.itemCount(sharedItems.count, lang)
        } else if sharedIsFile {
            let bytes = (try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            sharedDetail = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        } else {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: first, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            sharedDetail = LStr.itemCount(entries.count, lang)
        }
    }

    // 有文本时一律走虚拟根：纯文本→makeItems([])=空虚拟根（二维码另直指 /ls/text）；
    // 文本+文件→文件项的虚拟根（文本经 server.sharedText 单独挂上、不进 items）。文本经 /ls/text 提供。
    private var currentShare: FileServer.Share {
        if hasText { return .multiple(FileServer.Share.makeItems(sharedItems)) }
        switch sharedItems.count {
        case 0:  return .multiple([])   // 只收文本（无任何分享内容）：空虚拟根，服务靠 /ls/send + /ls/text
        case 1:  return sharedIsFile ? .file(sharedItems[0]) : .directory(sharedItems[0])
        default: return .multiple(FileServer.Share.makeItems(sharedItems))
        }
    }

    // MARK: - 访客上传

    // 仅「单个文件夹」分享有上传落点；单文件/多选时设置页开关置灰。
    // 附带文本会把分享转成虚拟根（无单一落点），故此时上传也不可用。
    var canToggleUpload: Bool { sharedItems.count == 1 && !sharedIsFile && !hasText }

    func setUploadAllowed(_ on: Bool) {
        permission.add = on && canToggleUpload
        server?.uploadEnabled = permission.add
    }

    private func resetUpload() {
        permission.add = false
        server?.uploadEnabled = false
        received = []
    }

    // 收到访客上传（FileServer 回调已 hop 回主线程）。同名（覆盖前缀去重）不重复插入。
    private func recordReceived(_ url: URL) {
        received.removeAll { $0 == url }
        received.insert(url, at: 0)
        if received.count > 5 { received = Array(received.prefix(5)) }
    }

    func revealReceived(_ url: URL) {
        revealInFinder(url)
    }

    // 在 Finder 中定位一项（文件与文件夹一律「在父目录中选中」）。多选卡片菜单与收件卡片共用。
    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 收件箱（收文本 v2）

    // 「允许收文本」闸门。开：不限分享形态都能开，开了就把服务拉起（无分享时即「只收模式」），不轮换 token、
    // 不重启（运行中只切 server 标志，发送表单随之显隐、已发链接继续有效）。关：若再无其它分享则停服务。
    func setTextInboxEnabled(_ on: Bool) {
        guard on != textInboxEnabled else { return }
        textInboxEnabled = on
        UserDefaults.standard.set(on, forKey: textInboxKey)
        if isRunning {
            if isServing { server?.textInboxEnabled = on }   // 仍有理由服务：原地切标志
            else { stop() }                                  // 关掉且无其它分享 → 拆服务，回到空状态
        } else if isServing {
            start()                                          // 从空状态开启 → 起服务（只收模式）
        }
    }

    // 停止传递文本：一步彻底结束——撤下文本、关收件箱、停服务、回功能选择页。
    // 区别于编辑器里的「撤回」（只撤文本、保留接收）；这是文本场景对齐文件票据「停止」的总开关。
    func stopTextTransfer() {
        sharedText = nil
        textDraft = ""
        if textInboxEnabled {
            textInboxEnabled = false
            UserDefaults.standard.set(false, forKey: textInboxKey)
        }
        UserDefaults.standard.removeObject(forKey: sharedTextKey)   // 撤下即清，不在磁盘残留口令
        stop()            // 停服务：端口归零、token 轮换作废所有旧链接/cookie/二维码
        screen = .share   // 回功能主页（此时无任何分享 → HomeScreen）
    }

    // 「记住收到的文本」开关。开：立即把当前收件箱落盘；关：抹掉磁盘留存（内存当次仍在，退出即忘）。
    func setPersistReceivedText(_ on: Bool) {
        guard on != persistReceivedText else { return }
        persistReceivedText = on
        UserDefaults.standard.set(on, forKey: persistReceivedKey)
        if on { saveReceivedTexts() }
        else { UserDefaults.standard.removeObject(forKey: receivedTextsKey) }
    }

    // 收到手机投递的文本（FileServer 回调已 hop 回主线程）。新→旧插入，满 100 条挤掉最旧。
    // 未读口径：人已在传递文本页（收件箱就在眼前）收到的直接算已读、不堆红点；在别处收到才计未读。
    private func recordReceivedText(_ rt: ReceivedText) {
        receivedTexts.insert(rt, at: 0)
        if receivedTexts.count > 100 { receivedTexts = Array(receivedTexts.prefix(100)) }
        if screen != .text { unreadReceived += 1 }
        saveReceivedTextsIfNeeded()
    }

    // 复制一条收到的文本到剪贴板，并清未读（视作已读）。
    func copyReceivedText(_ rt: ReceivedText) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rt.text, forType: .string)
        markReceivedRead()
    }

    func deleteReceivedText(_ rt: ReceivedText) {
        receivedTexts.removeAll { $0.id == rt.id }
        saveReceivedTextsIfNeeded()
    }

    func clearReceivedTexts() {
        receivedTexts.removeAll()
        unreadReceived = 0
        saveReceivedTextsIfNeeded()
    }

    func markReceivedRead() { unreadReceived = 0 }

    private func saveReceivedTextsIfNeeded() { if persistReceivedText { saveReceivedTexts() } }
    private func saveReceivedTexts() {
        if let data = try? JSONEncoder().encode(receivedTexts) {
            UserDefaults.standard.set(data, forKey: receivedTextsKey)
        }
    }
    private func loadReceivedTexts() {
        guard let data = UserDefaults.standard.data(forKey: receivedTextsKey),
              let list = try? JSONDecoder().decode([ReceivedText].self, from: data) else { return }
        receivedTexts = list
    }

    // MARK: - 启停 / 端口

    func start() {
        guard isServing else { return }
        refreshNetwork()
        let fs = FileServer(share: currentShare, token: token)
        fs.sharedText = hasText ? sharedText : nil
        fs.uploadEnabled = permission.add && canToggleUpload
        fs.textInboxEnabled = textInboxEnabled
        fs.onUpload = { url in   // socket 线程 → 主线程
            Task { @MainActor [weak self] in self?.recordReceived(url) }
        }
        fs.onReceiveText = { rt in   // socket 线程 → 主线程
            Task { @MainActor [weak self] in self?.recordReceivedText(rt) }
        }
        let prefer = [configuredPort] + fallbackPorts.filter { $0 != configuredPort }
        // 「仅当前网络可见」开 → 只绑选中网卡；无选中网卡（无网）时退回全接口，避免直接挂掉。
        let bindIP = bindSelectedOnly ? selectedInterface?.ip : nil
        fs.listenAddress = bindIP
        do {
            port = try fs.start(preferredPorts: prefer)
            server = fs
            isRunning = true
            lastError = nil
            startViewerPolling()
        } catch {
            // 绑定指定网卡失败（IP 刚因 DHCP/切网消失）：退回全接口重试一次，给提示但不让分享中断。
            if bindIP != nil {
                fs.listenAddress = nil
                if let p = try? fs.start(preferredPorts: prefer) {
                    port = p
                    server = fs
                    isRunning = true
                    lastError = LStr.ifaceUnavailable(lang)
                    startViewerPolling()
                    return
                }
            }
            lastError = LStr.startFailed(error.localizedDescription, lang)
            isRunning = false
        }
    }

    // 在不轮换 token 的前提下重绑监听地址（切网卡 / 切「仅当前网络可见」用）：stop() 会换钥匙、
    // 作废已发链接，这里只想换 socket 绑定，故单独走——保留 self.token，已分发的二维码继续有效。
    private func rebindServer() {
        guard isRunning else { return }
        viewerTimer?.invalidate(); viewerTimer = nil
        server?.stop()
        server = nil
        start()   // 复用 self.token，仅监听地址/端口随当前选择重算
    }

    // 切换信号源：默认（绑全接口）下纯展示用途，沿用旧行为不重启；开了「仅当前网络可见」才需重绑到新网卡。
    func selectInterface(_ iface: NetworkInterface) {
        guard iface != selectedInterface else { return }
        selectedInterface = iface
        if isRunning && bindSelectedOnly { rebindServer() }
    }

    func setBindSelectedOnly(_ on: Bool) {
        guard on != bindSelectedOnly else { return }
        bindSelectedOnly = on
        UserDefaults.standard.set(on, forKey: bindSelectedOnlyKey)
        if isRunning { rebindServer() }   // 立即重绑：开=收窄到选中网卡，关=放开到全接口
    }

    func stop() {
        viewerTimer?.invalidate()
        viewerTimer = nil
        viewerCount = 0
        viewers = []
        server?.stop()
        server = nil
        isRunning = false
        port = 0
        token = Token.generate()   // 停止即撕毁已发出的链接；「重新广播」发的是新钥匙
    }

    // 轮询活跃访客数（activeViewers 锁内取快照，保持 server → state → view 的单向数据流）。
    private func startViewerPolling() {
        viewerTimer?.invalidate()
        viewerTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                let infos = self.server?.activeViewerInfos() ?? []
                self.viewers = infos
                self.viewerCount = infos.count
            }
        }
    }

    func toggle() { isRunning ? stop() : start() }

    // 清除当前分享：清空选择。收件箱关 → 停服务回到空状态（初始拖拽屏）；收件箱开 → 不停服务、转入
    // 「只收文本」模式（换钥匙作废旧分享链接、QR 改指 /ls/text）。历史里仍保留该条，可一键重新分享。
    func clearShare() {
        sharedItems = []
        sharedIsFile = false
        sharedDetail = nil
        sharedText = nil   // 撤下当前广播的文本
        textDraft = ""     // 「清除」是彻底复位：连草稿一起清，不在内存里留着上次文本
        resetUpload()
        UserDefaults.standard.removeObject(forKey: sharedTextKey)   // 不在磁盘上残留文本（同「撤下即清」）
        screen = .share
        if isServing {
            token = Token.generate()   // 旧分享链接/cookie/二维码作废
            if isRunning { pushToServer() } else { start() }
        } else {
            stop()
        }
    }

    // 应用新监听端口：持久化配置；运行中则重启服务（已分发链接需更新）。
    func applyPort(_ p: in_port_t) {
        configuredPort = p
        UserDefaults.standard.set(Int(p), forKey: portKey)
        guard isRunning, !isEmpty else { return }
        stop()
        start()
        if isRunning && port != p {
            lastError = LStr.portFallback(requested: p, actual: port, lang)
        }
    }

    // MARK: - 最近分享 / 历史

    private func recordRecent() {
        let entry: RecentShare?
        if !sharedItems.isEmpty {
            entry = RecentShare(paths: sharedItems.map(\.path), isFile: sharedIsFile,
                                detail: sharedDetail ?? "", date: Date(), text: nil)
        } else if hasText, persistText, let text = sharedText {
            // 纯文本分享：仅在「记住分享的文本」开启时落历史（默认关 → 文本不留痕、可删见 deleteRecent）。
            entry = RecentShare(paths: [], isFile: false, detail: LStr.charCount(text.count, lang),
                                date: Date(), text: text)
        } else {
            entry = nil
        }
        guard let entry else { return }
        recents.removeAll { $0.id == entry.id }
        recents.insert(entry, at: 0)
        if recents.count > 12 { recents = Array(recents.prefix(12)) }
        saveRecents()
    }

    // 重新分享某条历史：等价于重新选中它。文本条目直接重新广播该段文本；
    // 文件条目按路径恢复——多选时过滤掉已不存在的项，全缺失才移除该条。
    func reshare(_ r: RecentShare) {
        if let text = r.text {
            recents.removeAll { $0.id == r.id }   // setSharedText 会把它重新记到顶部（若 persistText 开）
            setSharedText(text)
            return
        }
        let fm = FileManager.default
        let existing = r.paths.filter { fm.fileExists(atPath: $0) }
        guard !existing.isEmpty else {
            recents.removeAll { $0.id == r.id }; saveRecents()
            lastError = LStr.shareGone(lang)
            return
        }
        recents.removeAll { $0.id == r.id }   // 路径子集变化时，避免残留旧记录
        setShared(existing.map { URL(fileURLWithPath: $0) })
        if existing.count < r.paths.count {
            lastError = LStr.someItemsGone(r.paths.count - existing.count, lang)
        }
    }

    // 清空历史，但保留当前选中的那条分享（文本/文件一视同仁）；无当前分享则全清。
    func clearRecents() {
        if isEmpty { recents.removeAll() }
        else { recents.removeAll { !isCurrentShare($0) } }
        saveRecents()
    }

    // 是否为「当前选中的分享」那条：文本比内容、文件比路径集合（不要求正在运行）。
    private func isCurrentShare(_ r: RecentShare) -> Bool {
        if let text = r.text { return isTextOnly && sharedText == text }
        return !r.paths.isEmpty && Set(r.paths) == currentSharePaths
    }

    // 删除单条历史（文本/文件一视同仁）。不影响当前正在直播的分享——历史与 live 是两回事。
    func deleteRecent(_ r: RecentShare) {
        recents.removeAll { $0.id == r.id }
        saveRecents()
    }

    // 是否为当前正在广播的那条历史。文本条目：纯文本分享且内容一致；文件条目：路径集合一致。
    func isLive(_ r: RecentShare) -> Bool {
        if let text = r.text { return isRunning && isTextOnly && sharedText == text }
        return isRunning && Set(r.paths) == currentSharePaths
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
    func goShare()      { screen = .share }   // 回功能主页（launchpad）
    func enterFile()    { screen = .file }    // 进文件票据二级页（二维码 + 操作）
    func openText()     { screen = .text }   // 进传递文本二级页（收/发合一）

    func setAppearance(_ a: AppearancePref) {
        appearance = a
        UserDefaults.standard.set(a.rawValue, forKey: appearanceKey)
    }

    // 当前原生界面语言（每个原生调用点读它；改 langPref 即触发全屏重渲染，与切外观同机制）。
    var lang: Lang { Lang.resolve(langPref) }

    func setLangPref(_ p: LangPref) {
        langPref = p
        UserDefaults.standard.set(p.rawValue, forKey: langPrefKey)
        Lang.current = Lang.resolve(p)   // 同步快照给菜单/命令构造处
    }

    func setShowRecents(_ on: Bool) {
        showRecents = on
        UserDefaults.standard.set(on, forKey: showRecentsKey)
    }

    // 「记住分享的文本」开关。开：把当前文本写盘；关：抹掉持久化的文本 + 历史里所有文本条目（隐私默认收敛）。
    func setPersistText(_ on: Bool) {
        persistText = on
        UserDefaults.standard.set(on, forKey: persistTextKey)
        if on {
            if let t = sharedText, !t.isEmpty { UserDefaults.standard.set(t, forKey: sharedTextKey) }
        } else {
            UserDefaults.standard.removeObject(forKey: sharedTextKey)
            recents.removeAll { $0.text != nil }
            saveRecents()
        }
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
    func installCLI()   { cliTask(install: true) { try CLIInstaller.install() } }
    func uninstallCLI() { cliTask(install: false) { try CLIInstaller.uninstall() } }

    private func cliTask(install: Bool, _ work: @escaping @Sendable () throws -> Void) {
        let lang = self.lang   // 在 MainActor 上快照，detached 任务里直接用
        Task.detached { [weak self] in
            var failure: String?
            do {
                try work()
            } catch is CLIInstaller.Cancelled {
                // 用户在授权框点了取消，不当作错误
            } catch {
                failure = LStr.cliTaskFailed(install: install, reason: error.localizedDescription, lang)
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
