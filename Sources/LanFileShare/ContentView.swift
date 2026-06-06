import SwiftUI
import UniformTypeIdentifiers

// 单窗口 UI（暖纸张 × 信号广播）：刊头 + 信号源(二维码/频率/链接) + 分享对象底座。
// 三态：未选分享对象 / 未接入局域网 / 广播中。分享对象可为文件夹或单个文件。视觉系统见 Theme.swift。
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var appeared = false
    @State private var showHelp = false
    @State private var isDropTargeted = false   // 拖拽悬停态，驱动高亮蒙层

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 18) {
                masthead
                content
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: 430)                                   // 内容收成定宽列
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // 在窗口内水平居中
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 22)
        }
        .frame(minWidth: 460, minHeight: 700)   // 背景填满整窗，宽度交给 defaultSize / 用户拖拽
        .preferredColorScheme(.light)
        .onAppear { appeared = true }
        // 整窗接收 Finder 拖拽：文件或文件夹拖进来即开始分享（无需点按钮）
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted.animation(.easeOut(duration: 0.15))) { handleDrop($0) }
        .overlay { if isDropTargeted { dropOverlay } }
    }

    // 拖入时覆盖整窗的高亮提示：朱红实线套准框 + 引导文案（弃用虚线，更像「就位框」而非通用上传区）。
    private var dropOverlay: some View {
        ZStack {
            Palette.paper.opacity(0.66)
            VStack(spacing: 14) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 40, weight: .regular)).foregroundStyle(Palette.signal)
                Text("松开即可分享").font(.serif(22)).foregroundStyle(Palette.ink)
                Text("文件夹 → 列表浏览 · 单个文件 → 扫码直接打开")
                    .font(.mono(10.5)).tracking(0.3).foregroundStyle(Palette.inkSoft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.signal, lineWidth: 2)
                .padding(12)
        )
        .overlay(CropMarks(color: Palette.signal.opacity(0.55), arm: 18).padding(2))
        .ignoresSafeArea()
        .transition(.opacity)
    }

    // 取第一个能解析成 file URL 的拖拽项，交给 setShared（它自行判断文件/文件夹）。
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { state.setShared(url) }
        }
        return true
    }

    // MARK: - 刊头

    private var masthead: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("局域网 · 只读分享")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.signal)
                Text("LocalShare")
                    .font(.serif(25)).foregroundStyle(Palette.ink)
            }
            Spacer()
            statusTag
        }
    }

    private var statusTag: some View {
        HStack(spacing: 7) {
            LiveDot(color: state.isRunning ? Palette.signal : Palette.inkSoft, live: state.isRunning)
            if state.isRunning {
                Text("广播中").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(":\(String(state.port))").font(.mono(11, .semibold)).foregroundStyle(Palette.signal)
            } else {
                Text("待机").font(.mono(10, .medium)).tracking(1).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().stroke(Palette.line, lineWidth: 1))
    }

    // MARK: - 主体（按状态切换）

    @ViewBuilder private var content: some View {
        if state.sharedURL == nil {
            emptyFolderState
        } else if !state.hasNetwork {
            noNetworkState
        } else {
            runningState
        }
    }

    // 未选分享对象：用印刷「套准角标」框出就位区（替代通用虚线框），暖纸微底 + 四角裁切线，
    // 一眼读作「把东西摆进这个框」——与二维码的角标语言一致，去 AI 感。
    private var emptyFolderState: some View {
        VStack {
            Spacer()
            VStack(spacing: 16) {
                Text("◐").font(.system(size: 54)).foregroundStyle(Palette.signal.opacity(0.85))
                VStack(spacing: 7) {
                    Text("把文件 / 文件夹拖到这里")
                        .font(.serif(20)).foregroundStyle(Palette.ink)
                    Text("即可向同一网络下的手机、电脑、平板只读广播")
                        .font(.system(size: 12.5)).foregroundStyle(Palette.inkSoft)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 10) {
                    Button("选择文件夹…") { state.pickFolder() }
                        .buttonStyle(SignalButtonStyle()).hoverLift()
                    Button("选择单个文件…") { state.pickFile() }
                        .buttonStyle(GhostButtonStyle()).hoverLift()
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48).padding(.horizontal, 30)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.surface.opacity(0.4)))
            .overlay(CropMarks(color: Palette.inkSoft.opacity(0.5), arm: 16).padding(7))
            Spacer()
        }
    }

    // 未接入局域网（但已选好分享对象）：顶部仍突出分享对象（卡内含更换/启停），下面引导接入网络。
    private var noNetworkState: some View {
        VStack(spacing: 16) {
            sharedCard
            Spacer()
            Text("⌁").font(.system(size: 58)).foregroundStyle(Palette.inkSoft.opacity(0.7))
            Text("未接入局域网").font(.serif(21)).foregroundStyle(Palette.ink)
            Text("先把这台 Mac 接入与目标设备相同的 WiFi /\n有线网络，再点下方刷新。")
                .font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center).lineSpacing(3)
            Button("刷新网络") { state.refreshNetwork() }
                .buttonStyle(GhostButtonStyle()).hoverLift().padding(.top, 4)
            Spacer()
        }
    }

    // 广播中：分享对象主卡(含更换/停止) → 二维码(渠道) → 频率 / 链接。
    private var runningState: some View {
        VStack(spacing: 16) {
            sharedCard.enter(appeared, 0.02)
            signalCard.enter(appeared, 0.08)
            if let iface = state.selectedInterface {
                frequency(iface).enter(appeared, 0.14)
            }
            if let url = state.primaryURL {
                linkBar(url).enter(appeared, 0.20)
            }
            if state.interfaces.count > 1 {
                interfacePicker.enter(appeared, 0.26)
            }
            if let local = state.localURL {
                Text("备用 · \(local)")
                    .font(.mono(10)).foregroundStyle(Palette.inkSoft.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .enter(appeared, 0.30)
            }
        }
    }

    // 分享对象主卡「广播单」：左侧信号脊条 + 类型印章 + 大字名 + 元数据，并就地集成「更换/停止」——
    // 把「在分享什么」与「换成什么」合为一处。弃用淡红圆角卡（太通用），走印刷分发单语言：暖纸面 + 信号脊。
    private var sharedCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    typeChip
                    Text(state.sharedURL?.lastPathComponent ?? "")
                        .font(.serif(18, .semibold)).foregroundStyle(Palette.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Button("更换") { state.pickAny() }.buttonStyle(GhostButtonStyle()).hoverLift()
                    Button(state.isRunning ? "停止" : "启动") { state.toggle() }
                        .buttonStyle(GhostButtonStyle()).hoverLift()
                }
            }
            metaLine   // 独占整行铺满卡片宽度，路径可显示更长
        }
        .padding(.leading, 16).padding(.trailing, 11).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.surface))
        .overlay(alignment: .leading) {                  // 信号脊条：竖向胶囊，像「正在播出」的频道索引
            Capsule().fill(Palette.signal).frame(width: 4).padding(.vertical, 12).padding(.leading, 5)
        }
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Palette.line, lineWidth: 1))
        .shadow(color: Palette.ink.opacity(0.06), radius: 10, x: 0, y: 5)
    }

    // 元数据 + 路径整行：大小/项数 · 可点击路径（左，铺满）；拷贝按钮（右，常驻）。
    private var metaLine: some View {
        HStack(spacing: 6) {
            if let detail = state.sharedDetail {
                Text(detail).font(.mono(10, .medium)).foregroundStyle(Palette.inkSoft).layoutPriority(1)
                Text("·").font(.mono(10)).foregroundStyle(Palette.inkSoft.opacity(0.45))
            }
            PathLink(text: prettyPath,
                     help: state.sharedIsFile ? "在 Finder 中显示该文件" : "在 Finder 中打开该文件夹") {
                revealShared()
            }
            Spacer(minLength: 6)
            Button { copyPath() } label: {
                Image(systemName: "doc.on.doc").font(.system(size: 9.5, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(Palette.inkSoft.opacity(0.7))
            .hoverLift().help("拷贝完整路径")
        }
    }

    // 类型印章：类别（PDF/视频/图片/网页…，图标随类型变）+ 具体格式（小写扩展名，如 png/mp4），两枚同一样式。
    private var typeChip: some View {
        let url = state.sharedURL ?? URL(fileURLWithPath: "/")
        let cat = FileType.category(of: url, isDir: !state.sharedIsFile)
        return HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: cat.sfSymbol).font(.system(size: 9, weight: .semibold))
                Text(chipLabel(cat)).font(.mono(9.5, .semibold)).tracking(0.3)
            }
            .chipStyle()
            if let sub = subtypeLabel(for: url, cat: cat) {
                Text(sub).font(.mono(9.5, .semibold)).tracking(0.3).chipStyle()
            }
        }
    }

    // 印章文案：目录→「文件夹」、未识别类型→「文件」，其余沿用类别中文名。
    private func chipLabel(_ c: FileCategory) -> String {
        switch c {
        case .dir:   return "文件夹"
        case .other: return "文件"
        default:     return c.displayName
        }
    }

    // 具体格式标签：文件的小写扩展名；目录、无扩展名、或与类别名重复（如 PDF·pdf）时不显示。
    private func subtypeLabel(for url: URL, cat: FileCategory) -> String? {
        guard cat != .dir else { return nil }
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, ext != cat.displayName.lowercased() else { return nil }
        return ext
    }

    // 路径以 ~ 缩写家目录，更短更易读。
    private var prettyPath: String {
        guard let path = state.sharedURL?.path else { return "" }
        return (path as NSString).abbreviatingWithTildeInPath
    }

    // 信号源卡片：电波环 + 二维码 + 套准角标
    private var signalCard: some View {
        VStack(spacing: 16) {
            ZStack {
                BroadcastRings().frame(width: 250, height: 250)
                if let qr = state.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none).resizable()
                        .frame(width: 212, height: 212)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
                        .overlay(CropMarks(color: Palette.inkSoft.opacity(0.5)).padding(-9))
                        .shadow(color: Palette.ink.opacity(0.12), radius: 18, x: 0, y: 10)
                }
            }
            .frame(height: 250)
            Text(state.sharedIsFile ? "扫码查看文件" : "扫码浏览文件夹")
                .font(.mono(10)).tracking(0.3).foregroundStyle(Palette.inkSoft)
        }
    }

    // 频率读数：IP 大字 + 端口强调
    private func frequency(_ iface: NetworkInterface) -> some View {
        VStack(spacing: 2) {
            Text("或在浏览器输入").font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(Palette.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(iface.ip).font(.mono(26, .medium)).foregroundStyle(Palette.ink)
                Text(":\(String(state.port))").font(.mono(26, .semibold)).foregroundStyle(Palette.signal)
            }
            .textSelection(.enabled)
        }
    }

    // 链接条：完整 URL + 复制 / 打开
    private func linkBar(_ url: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
            Text(url)
                .font(.mono(11.5)).foregroundStyle(Palette.inkSoft)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle()).hoverLift().help("复制链接")
            Button { open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(IconButtonStyle()).hoverLift().help("在本机浏览器打开（自测）")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }

    // 信号源（网卡）选择
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
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().stroke(Palette.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    // MARK: - 底座

    private var footer: some View {
        VStack(spacing: 12) {
            if let err = state.lastError {
                Text(err).font(.system(size: 11.5)).foregroundStyle(Palette.signal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button { showHelp.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "questionmark.circle").font(.system(size: 11))
                        Text("连不上？").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Palette.inkSoft)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHelp, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 11) {
                        Text("连不上？逐条排查")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink)
                        troubleshootRow("1", "确认两台设备连的是同一个 WiFi / 网络。")
                        troubleshootRow("2", "首次启动若弹出防火墙提示，请点「允许」。")
                        troubleshootRow("3", "公司 / 公共 WiFi 常开「设备隔离」，会阻止互访，换个网络试试。")
                    }
                    .padding(16)
                    .frame(width: 312)
                }
                Spacer()
                Text(appVersion)
                    .font(.mono(9.5)).foregroundStyle(Palette.inkSoft.opacity(0.5))
                    .textSelection(.enabled)
            }
        }
    }

    private func troubleshootRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.mono(10, .semibold)).foregroundStyle(Palette.signal)
                .frame(width: 16, height: 16)
                .background(Circle().stroke(Palette.signal.opacity(0.4), lineWidth: 1))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft).lineSpacing(2)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    // 拷贝分享对象的完整绝对路径（非 ~ 缩写）。
    private func copyPath() { copy(state.sharedURL?.path ?? "") }

    // 在 Finder 中定位分享对象：单文件→选中该文件（顺带打开其所在目录），文件夹→直接打开。
    private func revealShared() {
        guard let url = state.sharedURL else { return }
        if state.sharedIsFile {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // 版本号取自 bundle（随 release/tag 自动同步）；swift run 裸二进制无 bundle，回退 dev。
    private var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v\($0)" } ?? "dev"
    }
}

private extension View {
    // 类型印章统一样式：信号色描边胶囊。
    func chipStyle() -> some View {
        foregroundStyle(Palette.signal)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().stroke(Palette.signal.opacity(0.4), lineWidth: 1))
    }
}

// 路径链接：hover 显示下划线 + 手型光标，点击执行 action（在 Finder 中定位）。
private struct PathLink: View {
    let text: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Text(text)
            .underline(hover, color: Palette.inkSoft.opacity(0.55))
            .font(.mono(10))
            .foregroundStyle(Palette.inkSoft.opacity(hover ? 1 : 0.8))
            .lineLimit(1).truncationMode(.middle)
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help(help)
    }
}
