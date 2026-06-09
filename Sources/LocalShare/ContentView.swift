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
        .frame(minWidth: 390, minHeight: 620)
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
            if state.sharedURL == nil {
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
                Text("文件夹 → 列表浏览 · 单个文件 → 扫码直接打开")
                    .font(.mono(10.5)).foregroundStyle(t.inkMute)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.accent, lineWidth: 2).padding(12))
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { state.setShared(url) }
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
private struct OverlayScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }
    private func apply(from view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
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
            }
        } content: {
            VStack(spacing: 0) {
                dropZone
                RecentSharesView(t: t, items: state.recents.filter { $0.exists },
                                 onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
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
    var body: some View {
        let ps = permSummary(state.permission)
        ScreenFrame(t: t) {
            HStack(spacing: 8) {
                Text("LocalShare").font(.display(22, .semibold)).tracking(-0.2).foregroundStyle(t.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                StatusPill(t: t, running: state.isRunning, host: state.selectedInterface?.ip,
                           port: state.isRunning ? state.port : state.configuredPort)
            }
        } content: {
            VStack(spacing: 16) {
                ticket(ps)
                actions
                if state.interfaces.count > 1 { interfacePicker }
                if state.sharedIsFile {
                    RecentSharesView(t: t, items: state.recents.filter { $0.exists && $0.path != state.sharedURL?.path },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
                }
            }
        }
    }

    private func ticket(_ ps: PermSummary) -> some View {
        TicketCard(t: t) {
            state.sharedIsFile ? AnyView(fileStub(ps)) : AnyView(folderStub(ps))
        } pass: {
            qrPass
        }
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

    // 通行区：QR + 说明 + 复制条
    private var qrPass: some View {
        let running = state.isRunning
        let caption = state.sharedIsFile ? "扫码查看 · 同一 Wi-Fi" : "扫码浏览全部文件 · 同一 Wi-Fi"
        return VStack(spacing: 0) {
            QRCard(image: state.qrImage, size: 172, dimmed: !running).padding(.top, 22)
            Text(running ? caption : "已停止广播").font(.sans(13, .semibold)).foregroundStyle(t.ink).padding(.top, 14)
            CopyPill(t: t, value: state.primaryURL ?? "", display: state.displayAddress ?? "—",
                     compact: true, onOpen: openInBrowser).padding(.top, 10)
            if let local = state.localURL {
                // 备用地址（主机名 / .local）紧贴主地址、归入卡内，保持内聚。左缩进对齐上方地址文字。
                BackupAddressRow(t: t, full: local) {
                    if let url = URL(string: local) { NSWorkspace.shared.open(url) }
                }
                .padding(.top, 7).padding(.leading, 12)
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
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
                Button(iface.displayName) { state.selectedInterface = iface }
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

// MARK: - 设置（端口 + 只读权限）

private struct SettingsScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var portText = ""
    var body: some View {
        let pv = validatePort(portText)
        let pColor = pv.state == .ok ? t.ok : (pv.state == .occupied ? t.warn : t.danger)
        let changed = (Int(portText) ?? -1) != Int(state.configuredPort)
        let ps = permSummary(state.permission)
        return ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: "返回") { state.goShare() }
                Text("分享设置").font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // 端口
                SectionLabel(t: t, text: "监听端口").padding(.bottom, 8)
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

                if pv.state != .invalid && changed {
                    PrimaryButton(t: t, title: "应用新端口（重启服务）", systemImage: "arrow.clockwise") {
                        apply(pv, changed: changed)
                    }
                    .padding(.top, 12)
                }

                // 权限
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

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(t.accent).padding(.top, 1)
                    Text("当前为只读分享 · 访客只能查看和下载。写入权限（上传 / 编辑 / 删除）尚未开放。")
                        .font(.sans(11.5)).foregroundStyle(t.dark ? t.ink : Color(hex: 0x8a3a1e)).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accentSoft))
                .padding(.top, 12)

                // 外观
                SectionLabel(t: t, text: "外观").padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 8) {
                    appearanceSeg("跟随系统", .system)
                    appearanceSeg("浅色", .light)
                    appearanceSeg("深色", .dark)
                }

                // 窗口
                SectionLabel(t: t, text: "窗口").padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 12) {
                    Text("恢复默认窗口尺寸").font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                    Spacer(minLength: 8)
                    GhostButton(t: t, title: "恢复默认", systemImage: "arrow.counterclockwise") {
                        state.resetWindowSize()
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .onAppear { portText = String(state.configuredPort) }
    }

    private func appearanceSeg(_ label: String, _ pref: AppState.AppearancePref) -> some View {
        let on = state.appearance == pref
        return Button { state.setAppearance(pref) } label: {
            Text(label).font(.sans(13, on ? .semibold : .medium))
                .foregroundStyle(on ? .white : t.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? t.accent : t.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? .clear : t.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func permRow(name: String, desc: String, locked: Bool, on: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                    if locked { Text("始终开启").font(.sans(11)).foregroundStyle(t.inkFaint) }
                }
                Text(desc).font(.sans(11.5)).foregroundStyle(t.inkMute)
            }
            Spacer()
            ToggleSwitch(t: t, isOn: on, locked: locked)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Rectangle().fill(t.line).frame(height: 1) }
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

// 历史 / 最近行用的图标：文件夹→FolderGlyph，文件→类型方块。
private struct RecentGlyph: View {
    let t: Theme
    var item: RecentShare
    var size: CGFloat
    var body: some View {
        if item.isFile {
            let url = URL(fileURLWithPath: item.path)
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
