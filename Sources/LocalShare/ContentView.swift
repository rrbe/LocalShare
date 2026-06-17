import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 单窗口 UI（票据风）。权威规范见 DESIGN.md。窗口为无边框工具窗（红绿灯浮于内容左上），
// 内容收成约 420 宽的竖列，顶部留 40 给红绿灯。屏幕路由：分享 / 设置 / 历史；分享屏据状态再分
// 空状态 / 单文件票据 / 文件夹票据 / 未接入网络。主题随系统浅深切换（Theme.make）。
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) private var systemScheme
    @State private var isDropTargeted = false

    // 解析「跟随系统 / 浅色 / 深色」偏好为实际深浅。
    private var dark: Bool {
        switch state.appearance {
        case .system: return systemScheme == .dark
        case .light:  return false
        case .dark:   return true
        }
    }
    private var t: Theme { Theme.make(dark: dark) }
    // 强制窗口外观（含原生红绿灯区/弹层），跟随系统时交回 nil。
    private var forced: ColorScheme? {
        switch state.appearance {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    var body: some View {
        ZStack {
            t.bg.ignoresSafeArea()
            content
                .frame(maxWidth: 430)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        // 最小宽度对齐默认宽度（共用同一常量）：留出 min↔默认 的缝隙时，切换屏幕的瞬间内容会被
        // 短暂提议到更小的最小宽度再弹回，表现为一次横向闪烁；锁成同一值即无缝可闪。高度无此问题——
        // 内容恒比最小高度高（可滚动），永不会被压到最小高度。
        .frame(minWidth: AppState.defaultWindowWidth, minHeight: 620)
        .preferredColorScheme(forced)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(.easeOut(duration: 0.15))) { handleDrop($0) }
        .overlay { if isDropTargeted { dropOverlay } }
    }

    @ViewBuilder private var content: some View {
        switch state.screen {
        case .settings:
            SettingsScreen(t: t)
        case .history:
            HistoryScreen(t: t)
        case .share:
            if state.sharedItems.isEmpty {
                EmptyScreen(t: t, dragging: isDropTargeted)
            } else if !state.hasNetwork {
                NoNetworkScreen(t: t)
            } else {
                ShareScreen(t: t)
            }
        }
    }

    // 拖入整窗的高亮提示。
    private var dropOverlay: some View {
        ZStack {
            t.bg.opacity(0.72)
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down").font(.system(size: 40)).foregroundStyle(t.accent)
                Text("松开即可分享").font(.display(22)).foregroundStyle(t.ink)
                Text("文件夹 / 多项 → 列表浏览 · 单个文件 → 扫码直接打开")
                    .font(.mono(10.5)).foregroundStyle(t.inkMute)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.accent, lineWidth: 2).padding(12))
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let loadable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !loadable.isEmpty else { return false }
        // 收齐所有拖入项的 fileURL（回调异步、顺序不保证），全部回来后一次性按拖入顺序提交。
        // 回调可能并发，故对收集字典的写入串行化到 sync 队列。
        var byIndex = [Int: URL]()
        let sync = DispatchQueue(label: "localshare.drop.collect")
        let group = DispatchGroup()
        for (i, provider) in loadable.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                sync.async {
                    if let url, url.isFileURL { byIndex[i] = url }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            let urls = loadable.indices.compactMap { byIndex[$0] }
            if !urls.isEmpty { state.setShared(urls) }
        }
        return true
    }
}

// MARK: - 屏幕脚手架（顶留红绿灯 + 内容 + 底部 HelpRow）

private let hPad: CGFloat = 22

private struct ScreenFrame<Header: View, Body: View>: View {
    let t: Theme
    @ViewBuilder var header: () -> Header
    @ViewBuilder var content: () -> Body
    var body: some View {
        VStack(spacing: 0) {
            header()
                .padding(.horizontal, hPad).padding(.top, 40).padding(.bottom, 14)
            ScrollView {
                content().padding(.horizontal, hPad).padding(.bottom, 6)
                    .background(OverlayScrollers())
            }
            HelpRow(t: t).padding(.horizontal, hPad).padding(.vertical, 12)
        }
    }
}

// 把 SwiftUI ScrollView 底层的 NSScrollView 强制为 overlay 滚动条样式。
// 鼠标用户在系统「始终显示滚动条」下，默认会拿到常驻、挤占右侧宽度的 legacy 滚动条
//（`.scrollIndicators(.hidden)` 也压不住它）；改 overlay 后与触控板一致——空闲隐藏、
// 滚动/悬停时才细细淡入，且不占布局宽度。挂在内容里靠 enclosingScrollView 反查容器。
// 关键：必须在首帧绘制前同步改样式。若拖到下一个 runloop（DispatchQueue.async）才改，
// 内容超出视口的页（如设置页）会先按 legacy 滚动条占走右侧 ~15px 布一次，下一拍切 overlay
// 再把这 15px 还回去——肉眼即「内容向右撑开」的闪动。故改用视图入树回调即时应用，不延后。
private struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollerStyler() }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollerStyler)?.applyOverlay()
    }
}

// 入树即应用：viewDidMoveToSuperview / ToWindow 都在首帧绘制前同步触发，反查 enclosingScrollView
// 并切 overlay；任一时机还拿不到容器，后一个时机补上，全程无 async 延迟。
private final class ScrollerStyler: NSView {
    override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); applyOverlay() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); applyOverlay() }
    func applyOverlay() {
        guard let scroll = enclosingScrollView else { return }
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
    }
}

// MARK: - 空状态

private struct EmptyScreen: View {
    let t: Theme
    var dragging: Bool
    @EnvironmentObject var state: AppState
    var body: some View {
        let ps = permSummary(state.permission)
        ScreenFrame(t: t) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ps.eyebrow).font(.sans(11, .bold)).tracking(1.2).foregroundStyle(t.accent)
                    Text("LocalShare").font(.display(28, .semibold)).tracking(-0.3).foregroundStyle(t.ink)
                }
                Spacer()
                IdlePill(t: t, port: state.configuredPort)
                IconButton(t: t, systemImage: "gearshape", help: "设置") { state.openSettings() }
            }
        } content: {
            VStack(spacing: 0) {
                dropZone
                if state.showRecents {
                    RecentSharesView(t: t, items: state.recents.filter { $0.exists },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
                }
            }
        }
    }

    private var dropZone: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(t.accentSoft)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "arrow.up.to.line").font(.system(size: 24, weight: .medium)).foregroundStyle(t.accent))
                .padding(.bottom, 14)
            Text("拖拽文件或文件夹到这里").font(.sans(15.5, .semibold)).foregroundStyle(t.ink)
            Text("同一 Wi-Fi 下的设备即可扫码访问").font(.sans(12.5)).foregroundStyle(t.inkMute).padding(.top, 4)
            PrimaryButton(t: t, title: "选择文件或文件夹", systemImage: "doc.badge.plus") { state.pickAny() }
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 28)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(dragging ? t.accentSoft : t.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .foregroundStyle(dragging ? t.accent : t.lineStrong)
        )
    }
}

// MARK: - 分享屏（单文件 / 文件夹票据）

private struct ShareScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var showViewers = false   // 在线访客明细弹窗（点摘要行展开）
    var body: some View {
        let ps = permSummary(state.permission)
        ScreenFrame(t: t) {
            HStack(spacing: 8) {
                Text("LocalShare").font(.display(22, .semibold)).tracking(-0.2).foregroundStyle(t.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                StatusPill(t: t, running: state.isRunning, host: state.selectedInterface?.ip,
                           port: state.isRunning ? state.port : state.configuredPort)
                IconButton(t: t, systemImage: "gearshape", help: "设置") { state.openSettings() }
            }
        } content: {
            VStack(spacing: 16) {
                ticket(ps)
                if !state.received.isEmpty { receivedCard }
                actions
                if state.interfaces.count > 1 { interfacePicker }
                if state.sharedIsFile && state.showRecents {
                    RecentSharesView(t: t, items: state.recents.filter { $0.exists && Set($0.paths) != state.currentSharePaths },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
                }
            }
        }
    }

    private func ticket(_ ps: PermSummary) -> some View {
        TicketCard(t: t) {
            if state.isMultiple { AnyView(multipleStub(ps)) }
            else if state.sharedIsFile { AnyView(fileStub(ps)) }
            else { AnyView(folderStub(ps)) }
        } pass: {
            qrPass
        }
    }

    // 多项存根：叠放印章 + 「正在分享 N 项」+ 文件/文件夹分项概要 + 前几项名称预览。
    private func multipleStub(_ ps: PermSummary) -> some View {
        let items = state.sharedItems
        let dirCount = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        let fileCount = items.count - dirCount
        var parts: [String] = []
        if fileCount > 0 { parts.append("\(fileCount) 个文件") }
        if dirCount > 0 { parts.append("\(dirCount) 个文件夹") }
        let preview = items.prefix(3).map(\.lastPathComponent).joined(separator: "、")
            + (items.count > 3 ? " 等" : "")
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                MultiGlyph(t: t, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在分享 · \(ps.tag)").font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text("\(items.count) 项").font(.sans(16, .bold)).foregroundStyle(t.ink)
                    Text(parts.joined(separator: " · ")).font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t) { state.clearShare() }
            }
            MultiPreviewMenu(t: t, items: items, preview: preview) { state.revealInFinder($0) }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // 单文件存根
    private func fileStub(_ ps: PermSummary) -> some View {
        let url = state.sharedURL ?? URL(fileURLWithPath: "/")
        let cat = FileType.category(of: url, isDir: false)
        let catName = (cat == .other) ? "文件" : cat.displayName
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                TypeGlyph(t: t, category: cat, ext: url.pathExtension.lowercased(), size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ps.tag).font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text(url.lastPathComponent).font(.sans(14, .semibold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text("\(state.sharedDetail ?? "") · \(catName)").font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t) { state.clearShare() }
            }
            PathRow(t: t, url: url, isFile: true)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // 文件夹存根（含路径 + 权限 chips + 改权限入口）
    private func folderStub(_ ps: PermSummary) -> some View {
        let url = state.sharedURL ?? URL(fileURLWithPath: "/")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                FolderGlyph(t: t, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在分享文件夹 · \(ps.tag)").font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text(url.lastPathComponent).font(.sans(16, .bold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(state.sharedDetail ?? "").font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t) { state.clearShare() }
            }
            .padding(.horizontal, 18).padding(.top, 16)
            PathRow(t: t, url: url, isFile: false)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
            HStack(spacing: 6) {
                ForEach(Array(ps.chips.enumerated()), id: \.offset) { i, c in
                    PermChip(t: t, text: c, hot: ps.writable && i > 0)
                }
                Spacer()
                Button { state.openSettings() } label: {
                    Text("改权限 ›").font(.sans(11)).foregroundStyle(t.accent)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        }
    }

    // 访客新上传的文件（最多列 3 条，点击在 Finder 中显示）。换分享/清除时由 AppState 清空。
    private var receivedCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(t.accent).frame(width: 6, height: 6)
                Text("新收到").font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                Spacer()
                if state.received.count > 3 {
                    Text("\(state.received.count) 项").font(.mono(11)).foregroundStyle(t.inkFaint)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 5)
            ForEach(state.received.prefix(3), id: \.self) { url in
                ReceivedRow(t: t, url: url) { state.revealReceived(url) }
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 通行区：QR + 说明 + 复制条
    private var qrPass: some View {
        let running = state.isRunning
        let caption = state.isMultiple ? "扫码浏览已选项目 · 同一 Wi-Fi"
            : (state.sharedIsFile ? "扫码查看 · 同一 Wi-Fi" : "扫码浏览全部文件 · 同一 Wi-Fi")
        return VStack(spacing: 0) {
            QRCard(image: state.qrImage, size: 172, dimmed: !running).padding(.top, 22)
            Text(running ? caption : "已停止广播").font(.sans(13, .semibold)).foregroundStyle(t.ink).padding(.top, 14)
            CopyPill(t: t, value: state.primaryURL ?? "—",
                     compact: true, onOpen: openInBrowser).padding(.top, 10)
            if let local = state.localURL {
                // 备用地址（主机名 / .local）紧贴主地址、归入卡内，保持内聚。左缩进对齐上方地址文字。
                BackupAddressRow(t: t, full: local) {
                    if let url = URL(string: local) { NSWorkspace.shared.open(url) }
                }
                .padding(.top, 7).padding(.leading, 12)
            }
            // 在线访客：小绿点 + 摘要文案；点一下展开全部访客明细（设备名 / 完整 IP）。
            // 0 人时整行隐藏（不占位、不留空文案）。
            if running && state.viewerCount > 0 {
                Button { showViewers.toggle() } label: {
                    HStack(spacing: 6) {
                        Circle().fill(t.ok).frame(width: 6, height: 6)
                        Text(viewerText).font(.sans(11.5)).foregroundStyle(t.inkMute)
                            .lineLimit(1).truncationMode(.tail)
                        Image(systemName: "chevron.down").font(.sans(8, .semibold)).foregroundStyle(t.inkFaint)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
                .transition(.opacity)
                .popover(isPresented: $showViewers, arrowEdge: .bottom) {
                    ViewerListPopover(t: t, viewers: state.viewers)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.2), value: state.viewerCount > 0)
    }

    // 在线访客摘要：反查到设备名才领衔具名（单台直呼其名、多台「领衔 + 等 N 人」）；
    // 查不到则统一「N 人正在浏览」——不在摘要露 IP 尾号，完整 IP 留给展开列表。
    private var viewerText: String {
        let n = state.viewerCount
        if let name = state.viewers.first?.name, !name.isEmpty {
            return n <= 1 ? "\(name) 正在浏览" : "\(name) 等 \(n) 人正在浏览"
        }
        return "\(n) 人正在浏览"
    }

    @ViewBuilder private var actions: some View {
        if state.isRunning {
            HStack(spacing: 10) {
                GhostButton(t: t, title: state.sharedIsFile ? "更换文件" : "更换",
                            systemImage: "arrow.left.arrow.right", fullWidth: true) { state.pickAny() }
                DangerButton(t: t, title: "停止") { state.stop() }
            }
        } else {
            HStack(spacing: 10) {
                PrimaryButton(t: t, title: "重新广播", systemImage: "play.fill", fullWidth: true) { state.start() }
                GhostButton(t: t, title: "清除") { state.clearShare() }
            }
        }
    }

    private var interfacePicker: some View {
        Menu {
            ForEach(state.interfaces) { iface in
                Button(iface.displayName) { state.selectInterface(iface) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                Text(state.selectedInterface?.displayName ?? "选择信号源").font(.mono(11))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(t.ink)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().strokeBorder(t.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    private func openInBrowser() {
        guard let s = state.primaryURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}

// 多选项目预览行：标签沿用原淡色名称预览（前 3 项 + 等），点击弹出全部分享项菜单，
// 选中即在 Finder 中显示——与单项分享的 PathRow、收件行同一交互语言（hover 下划线 + 手型）。
private struct MultiPreviewMenu: View {
    let t: Theme
    let items: [URL]
    let preview: String
    let reveal: (URL) -> Void
    @State private var hover = false
    var body: some View {
        Menu {
            Section("在 Finder 中显示") {
                ForEach(items, id: \.self) { url in
                    Button(url.lastPathComponent) { reveal(url) }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(preview)
                    .font(.sans(11.5))
                    .foregroundStyle(hover ? t.inkMute : t.inkFaint)
                    .underline(hover, color: t.inkFaint)
                    .lineLimit(2).truncationMode(.tail)
                    .multilineTextAlignment(.leading)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(hover ? t.accent : t.inkFaint)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        .help("在 Finder 中显示分享项")
    }
}

// 收件单行：类型小图标 + 文件名，悬停亮出跳转箭头（点击在 Finder 中显示）。
private struct ReceivedRow: View {
    let t: Theme
    let url: URL
    let reveal: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: reveal) {
            HStack(spacing: 9) {
                TypeGlyph(t: t, category: FileType.category(of: url, isDir: false),
                          ext: url.pathExtension.lowercased(), size: 26)
                Text(url.lastPathComponent).font(.sans(12.5, .medium)).foregroundStyle(t.ink)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hover ? t.accent : t.inkFaint)
            }
            .padding(.horizontal, 16).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hover ? t.surfaceAlt : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("在 Finder 中显示")
    }
}

// 在线访客明细弹窗：列出全部活跃访客（设备名优先，查不到显示完整 IP），最近活跃在前。
// 仅分享者本机可见——网页端永不外泄身份（见 FileServer.activeViewers）。
private struct ViewerListPopover: View {
    let t: Theme
    let viewers: [ViewerInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(t.ok).frame(width: 6, height: 6)
                Text("正在浏览").font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                Spacer(minLength: 16)
                Text("\(viewers.count) 人").font(.mono(11)).foregroundStyle(t.inkFaint)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
            ForEach(viewers) { v in
                // 左：身份（查到设备名则名字为主、完整 IP 作副行；查不到直接显示完整 IP）。
                // 右：本次浏览开始至今的时长，尾部对齐成一列，便于多人时纵向扫读。
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(v.fullLabel).font(.sans(12.5, .medium)).foregroundStyle(t.ink)
                            .lineLimit(1).truncationMode(.middle)
                        if !v.name.isEmpty {
                            Text(v.ip).font(.mono(10.5)).foregroundStyle(t.inkFaint)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(elapsedText(v.since)).font(.sans(10.5)).foregroundStyle(t.inkFaint)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 230)
    }

    // 「开始浏览」至今的时长，口语化粗粒度即可（随 AppState 2s 轮询刷新）。
    private func elapsedText(_ since: Date) -> String {
        let s = Int(Date().timeIntervalSince(since))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60) 分钟前" }
        if s < 86400 { return "\(s / 3600) 小时前" }
        return "\(s / 86400) 天前"
    }
}

// MARK: - 未接入局域网

private struct NoNetworkScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    var body: some View {
        ScreenFrame(t: t) {
            HStack {
                Text("LocalShare").font(.display(22, .semibold)).tracking(-0.2).foregroundStyle(t.ink)
                Spacer()
                StatusPill(t: t, running: false, port: state.configuredPort)
                IconButton(t: t, systemImage: "gearshape", help: "设置") { state.openSettings() }
            }
        } content: {
            VStack(spacing: 14) {
                Spacer(minLength: 60)
                Image(systemName: "wifi.slash").font(.system(size: 46)).foregroundStyle(t.inkFaint)
                Text("未接入局域网").font(.display(21)).foregroundStyle(t.ink)
                Text("先把这台 Mac 接入与目标设备相同的\nWi-Fi / 有线网络，再点下方刷新。")
                    .font(.sans(13)).foregroundStyle(t.inkMute)
                    .multilineTextAlignment(.center).lineSpacing(3)
                GhostButton(t: t, title: "刷新网络", systemImage: "arrow.clockwise") { state.refreshNetwork() }
                    .padding(.top, 4)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - 设置（网络 / 访问权限 / 外观 / 主界面 / 命令行工具）

private struct SettingsScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var portText = ""
    var body: some View {
        // portText 初始为空、onAppear 才填入当前端口；首帧若按空串校验会闪出「无效 + 放弃/应用」行再弹回。
        // 空串一律视作「当前生效端口」，让首帧与落定后一致，消除进入设置页时的这层闪烁。
        let effectivePort = portText.isEmpty ? String(state.configuredPort) : portText
        let pv = validatePort(effectivePort)
        let pColor = pv.state == .ok ? t.ok : (pv.state == .occupied ? t.warn : t.danger)
        let changed = !portText.isEmpty && (Int(portText) ?? -1) != Int(state.configuredPort)
        let ps = permSummary(state.permission)
        return ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: "返回") { state.goShare() }
                Text("分享设置").font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // MARK: 网络（监听端口 + 可见范围）
                SectionLabel(t: t, text: "网络").padding(.bottom, 8)

                // 监听端口：IP 前缀 + 端口输入框 + 实时可用性校验。
                HStack(spacing: 10) {
                    Text("\(state.selectedInterface?.ip ?? "本机") :").font(.mono(14)).foregroundStyle(t.inkMute)
                    TextField("", text: $portText)
                        .textFieldStyle(.plain)
                        .font(.mono(15, .bold)).foregroundStyle(t.ink)
                        .frame(width: 72)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.field))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(pv.state == .ok ? t.lineStrong : pColor, lineWidth: 1.5))
                        .onChange(of: portText) { portText = String($0.filter(\.isNumber).prefix(5)) }
                        .onSubmit { apply(pv, changed: changed) }
                    Spacer()
                    HStack(spacing: 5) {
                        Image(systemName: pv.state == .ok ? "checkmark" : "questionmark.circle")
                            .font(.system(size: 13, weight: .bold))
                        Text(pv.state == .ok ? "可用" : (pv.state == .occupied ? "被占用" : "无效"))
                            .font(.sans(11.5, .bold))
                    }
                    .foregroundStyle(pColor)
                }
                .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(pv.state == .ok ? t.line : pColor, lineWidth: 1))

                HStack(alignment: .top, spacing: 8) {
                    Text(pv.state == .ok ? "端口可用 · 修改后会重启服务，已分发的链接需更新。" : pv.message)
                        .font(.sans(11.5, pv.state == .ok ? .regular : .semibold))
                        .foregroundStyle(pv.state == .ok ? t.inkMute : pColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let s = pv.suggest {
                        Button { portText = String(s) } label: {
                            Text("改用 :\(String(s))").font(.sans(11.5, .bold)).foregroundStyle(t.accent)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(t.accentSoft))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)

                // 改了才出现这排操作：放弃（还原成当前生效端口，无效输入也可退回）+ 应用。
                // 用纯色文字而非实心全宽块——重启服务不是破坏性动作，不必视觉吓人。
                if changed {
                    HStack(spacing: 18) {
                        Spacer()
                        Button { portText = String(state.configuredPort) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold))
                                Text("放弃修改").font(.sans(13, .semibold))
                            }
                            .foregroundStyle(t.inkMute)
                        }
                        .buttonStyle(.plain)
                        if pv.state != .invalid {
                            Button { apply(pv, changed: changed) } label: {
                                Text("应用并重启").font(.sans(13, .semibold)).foregroundStyle(t.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 12)
                }

                // 仅当前网络可见：同属网络设置，紧随端口、以分隔线归组。只有同时连了多个网络时才有意义，
                // 故描述按是否多网卡分两种措辞，避免单网卡时给出空泛的“其它网络”字样。
                settingRow(top: true, title: "仅当前网络可见",
                           desc: state.interfaces.count > 1
                                ? "只在选中的信号源上开放，电脑连着的其它网络访问不到"
                                : "只在当前网络开放，日后接入别的网络时也访问不到") {
                    ToggleSwitch(t: t, isOn: state.bindSelectedOnly) { state.setBindSelectedOnly(!state.bindSelectedOnly) }
                }
                .padding(.top, 14)

                // MARK: 访问权限
                HStack {
                    SectionLabel(t: t, text: "访问权限")
                    Spacer()
                    Text("当前：\(ps.tag)").font(.sans(11, .bold))
                        .foregroundStyle(ps.writable ? t.accent : t.inkMute)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(Capsule().fill(ps.writable ? t.accentSoft : .clear))
                        .overlay(Capsule().strokeBorder(ps.writable ? .clear : t.line, lineWidth: 1))
                }
                .padding(.top, 24).padding(.bottom, 4)

                permRow(name: "读取与下载", desc: "允许查看和下载文件", locked: true, on: true)
                permRow(name: "允许上传",
                        desc: state.canToggleUpload ? "访客可把文件传进这个文件夹" : "仅分享单个文件夹时可用",
                        locked: !state.canToggleUpload,
                        on: state.permission.add, top: true) {
                    state.setUploadAllowed(!state.permission.add)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(t.accent).padding(.top, 1)
                    Text(ps.writable
                         ? "已开启上传 · 访客可向这个文件夹写入文件，请只把二维码交给信任的人。"
                         : "当前为只读分享 · 访客只能查看和下载。")
                        .font(.sans(11.5)).foregroundStyle(t.dark ? t.ink : Color(hex: 0x8a3a1e)).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accentSoft))
                .padding(.top, 12)

                // 明文传输提示：纯 LAN 不加密，公共网络下同网的人能看到内容。用克制的灰字、不进彩底警告框。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open").font(.system(size: 13)).foregroundStyle(t.inkMute).padding(.top, 1)
                    Text("同一网络下传输不加密 · 公共 Wi-Fi（咖啡馆 / 机场等）下同网的人可能看到内容，敏感文件别在这种网络分享。")
                        .font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                // MARK: 外观
                SectionLabel(t: t, text: "外观").padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 8) {
                    appearanceSeg("跟随系统", .system)
                    appearanceSeg("浅色", .light)
                    appearanceSeg("深色", .dark)
                }

                // MARK: 主界面（最近分享展示 + 窗口尺寸）
                SectionLabel(t: t, text: "主界面").padding(.top, 24).padding(.bottom, 4)
                settingRow(title: "展示最近分享", desc: "关闭后主界面不再列出最近分享") {
                    ToggleSwitch(t: t, isOn: state.showRecents) { state.setShowRecents(!state.showRecents) }
                }
                settingRow(top: true, title: "恢复默认窗口尺寸") {
                    GhostButton(t: t, title: "恢复默认", systemImage: "arrow.counterclockwise") {
                        state.resetWindowSize()
                    }
                }

                // MARK: 命令行工具
                // 裸二进制（swift run）没有 .app 可指：不给安装按钮，状态/卸载照常。
                SectionLabel(t: t, text: "命令行工具").padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("localshare").font(.mono(13.5, .bold)).foregroundStyle(t.ink)
                        Text(cliHint).font(.sans(11.5)).foregroundStyle(t.inkMute)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if state.cliStatus != .notInstalled {
                        Button { state.uninstallCLI() } label: {
                            Text("卸载").font(.sans(13, .semibold)).foregroundStyle(t.inkMute)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                    if state.cliStatus == .installed {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            Text("已安装").font(.sans(11.5, .bold))
                        }
                        .foregroundStyle(t.ok)
                    } else if CLIInstaller.binaryPath() != nil {
                        GhostButton(t: t,
                                    title: state.cliStatus == .notInstalled ? "安装" : "重新安装",
                                    systemImage: "terminal") {
                            state.installCLI()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear {
            portText = String(state.configuredPort)
            state.refreshCLIStatus()
        }
    }

    // 命令行工具状态行：已安装显示链接路径；链接归属不了当前进程（裸跑/指向别处）时
    // 直接亮出实际指向，让人自己判断；未装时一句话点明用途或受限原因。
    private var cliHint: String {
        switch state.cliStatus {
        case .installed:
            return CLIInstaller.linkPath
        case .stale(let dest):
            return "→ " + (dest as NSString).abbreviatingWithTildeInPath
        case .notInstalled:
            return CLIInstaller.binaryPath() != nil ? "在终端用 localshare 分享文件" : "以 app 包运行时可安装"
        }
    }

    private func appearanceSeg(_ label: String, _ pref: AppState.AppearancePref) -> some View {
        let on = state.appearance == pref
        return Button { state.setAppearance(pref) } label: {
            Text(label).font(.sans(13, on ? .semibold : .medium))
                .foregroundStyle(on ? .white : t.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? t.accent : t.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? .clear : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 通用设置行：「标题 +（可选）说明 + 右侧控件」。同一分组内多行靠 top 顶部分隔线对齐，
    // 紧贴小节标题的首行不画线（top 默认 false）——分隔线只用来区隔相邻行，不重复标题已有的分隔。
    private func settingRow<Trailing: View>(top: Bool = false, title: String, desc: String? = nil,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                if let desc {
                    Text(desc).font(.sans(11.5)).foregroundStyle(t.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }

    // 权限专用行（带「始终开启」标记与可锁定开关）。locked 且无 action = 锁定常开（读取）；
    // locked 且有 action = 当前形态不可用（开关置灰）。top 同 settingRow：仅相邻行间画分隔线。
    private func permRow(name: String, desc: String, locked: Bool, on: Bool, top: Bool = false,
                         action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                    if locked && action == nil { Text("始终开启").font(.sans(11)).foregroundStyle(t.inkFaint) }
                }
                Text(desc).font(.sans(11.5)).foregroundStyle(t.inkMute)
            }
            Spacer()
            ToggleSwitch(t: t, isOn: on, locked: locked, action: action ?? {})
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }

    private func apply(_ pv: PortCheck, changed: Bool) {
        guard pv.state != .invalid, changed, let p = Int(portText) else { return }
        state.applyPort(in_port_t(p))
        state.goShare()
    }
}

// MARK: - 分享历史

private struct HistoryScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    var body: some View {
        ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: "返回") { state.goShare() }
                Text("分享历史").font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                if !state.recents.isEmpty {
                    Button { state.clearRecents() } label: {
                        Text("清空").font(.sans(12)).foregroundStyle(t.inkMute)
                    }.buttonStyle(.plain)
                }
            }
        } content: {
            if state.recents.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 80)
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 38)).foregroundStyle(t.inkFaint)
                    Text("暂无分享历史").font(.sans(14, .semibold)).foregroundStyle(t.inkMute)
                }.frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(state.recents.enumerated()), id: \.element.id) { i, h in
                        historyRow(h, top: i > 0)
                    }
                }
            }
        }
    }

    private func historyRow(_ h: RecentShare, top: Bool) -> some View {
        let live = state.isLive(h)
        return HStack(spacing: 12) {
            RecentGlyph(t: t, item: h, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(h.name).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if live {
                        HStack(spacing: 4) {
                            StatusDot(color: t.accent, live: true, size: 5)
                            Text("进行中").font(.sans(10.5, .bold)).foregroundStyle(t.accent)
                        }
                    }
                }
                Text("\(h.detail) · \(friendlyDate(h.date))").font(.mono(11.5)).foregroundStyle(t.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if live {
                DangerButton(t: t, title: "停止") { state.stop() }
            } else {
                GhostButton(t: t, title: "重新分享", systemImage: "arrow.left.arrow.right") { state.reshare(h) }
            }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }
}

// MARK: - 最近分享模块（空状态 + 单文件分享复用）

private struct RecentSharesView: View {
    let t: Theme
    var items: [RecentShare]
    var onAll: () -> Void
    var onReshare: (RecentShare) -> Void
    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(t: t, text: "最近分享")
                    Spacer()
                    Button { onAll() } label: { Text("查看全部").font(.sans(12)).foregroundStyle(t.accent) }
                        .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
                ForEach(Array(items.prefix(2).enumerated()), id: \.element.id) { i, h in
                    HStack(spacing: 11) {
                        RecentGlyph(t: t, item: h, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.name).font(.sans(13, .semibold)).foregroundStyle(t.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text(friendlyDate(h.date)).font(.mono(11)).foregroundStyle(t.inkMute)
                        }
                        Spacer(minLength: 4)
                        GhostButton(t: t, title: "重新分享", systemImage: "arrow.left.arrow.right") { onReshare(h) }
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(t.line).frame(height: 1) } }
                }
            }
            .padding(.top, 22)
        }
    }
}

// 历史 / 最近行用的图标：多项→叠放方块，单文件夹→FolderGlyph，单文件→类型方块。
private struct RecentGlyph: View {
    let t: Theme
    var item: RecentShare
    var size: CGFloat
    var body: some View {
        if item.isMultiple {
            MultiGlyph(t: t, size: size)
        } else if item.isFile, let path = item.paths.first {
            let url = URL(fileURLWithPath: path)
            TypeGlyph(t: t, category: FileType.category(of: url, isDir: false),
                      ext: url.pathExtension.lowercased(), size: size)
        } else {
            FolderGlyph(t: t, size: size)
        }
    }
}

// MARK: - 底部帮助行

private struct HelpRow: View {
    let t: Theme
    @State private var show = false
    var body: some View {
        HStack {
            Button { show.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").font(.system(size: 12))
                    Text("连不上?").font(.sans(12.5, .medium))
                }
                .foregroundStyle(t.inkMute)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    Text("连不上？逐条排查").font(.sans(12, .semibold)).foregroundStyle(t.ink)
                    row("1", "确认两台设备连的是同一个 Wi-Fi / 网络。")
                    row("2", "首次启动若弹出防火墙提示，请点「允许」。")
                    row("3", "公司 / 公共 Wi-Fi 常开「设备隔离」，会阻止互访，换个网络试试。")
                    Rectangle().fill(t.line).frame(height: 1).padding(.vertical, 1)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(t.inkMute).frame(width: 16)
                        Text("传输不加密：公共 Wi-Fi 下同网的人可能看到内容，敏感文件别在这种网络分享。")
                            .font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                        Spacer(minLength: 0)
                    }
                }
                .padding(16).frame(width: 312)
            }
            Spacer()
            Text(appVersion).font(.mono(10)).foregroundStyle(t.inkFaint).textSelection(.enabled)
        }
    }
    private func row(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.mono(10, .semibold)).foregroundStyle(t.accent)
                .frame(width: 16, height: 16)
                .background(Circle().strokeBorder(t.accent.opacity(0.4), lineWidth: 1))
            Text(text).font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 工具

// 版本号取自 bundle；裸二进制无 bundle 回退 dev。
private var appVersion: String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
}

// 友好日期：今天/昨天 + 时刻，更早只给「M月d日」。
private func friendlyDate(_ date: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter()
    if cal.isDateInToday(date) { f.dateFormat = "今天 HH:mm" }
    else if cal.isDateInYesterday(date) { f.dateFormat = "昨天 HH:mm" }
    else { f.dateFormat = "M月d日" }
    return f.string(from: date)
}
