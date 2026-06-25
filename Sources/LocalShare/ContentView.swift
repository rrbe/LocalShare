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
                .frame(maxWidth: 470)
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
            if state.isEmpty {
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
                Text(L.dropToShare(state.lang)).font(.display(22)).foregroundStyle(t.ink)
                Text(L.dropHint(state.lang))
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

// MARK: - 文本编辑弹层（空状态「分享文本」/ 分享屏「编辑文本」共用）

// 离散提交：点「分享 / 更新」才把当前编辑器内容作为新分享广播（state.setSharedText）。
// 初值来自 textDraft（重启可回填上次内容）；清空再提交即撤下文本。
private struct TextEntrySheet: View {
    let t: Theme
    let isUpdate: Bool
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(t: Theme, initial: String, isUpdate: Bool) {
        self.t = t; self.isUpdate = isUpdate
        _text = State(initialValue: initial)
    }

    private var blank: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        let lang = state.lang
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L.textShareTitle(lang)).font(.display(18, .semibold)).foregroundStyle(t.ink)
                Spacer()
                IconButton(t: t, systemImage: "xmark", help: L.back(lang)) { dismiss() }
            }
            ZStack(alignment: .topLeading) {
                // placeholder 与编辑器文字起点都恰好落在 inset(8) 处：编辑器内部 lineFragmentPadding 归零、
                // textContainerInset 设成 (8,8)，placeholder 也用同值内边距 + 同字号等宽字体 → 严丝合缝。
                if text.isEmpty {
                    Text(L.textEditorPlaceholder(lang)).font(.mono(13)).foregroundStyle(t.inkFaint)
                        .padding(.horizontal, 8).padding(.vertical, 8).allowsHitTesting(false)
                }
                PlainTextEditor(text: $text, textColor: NSColor(t.ink), caret: NSColor(t.accent),
                                inset: 8, autoFocus: true)
                    .frame(minHeight: 210)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.field))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line, lineWidth: 1))
            PrimaryButton(t: t, title: isUpdate ? L.textUpdateAction(lang) : L.textShareAction(lang),
                          systemImage: "paperplane.fill") {
                state.setSharedText(text)
                dismiss()
            }
            .disabled(blank)
            .opacity(blank ? 0.5 : 1)
        }
        .padding(20)
        .frame(width: 380, height: 380)
        .background(t.bg)
    }
}

// 自带 NSTextView 的纯文本编辑器。SwiftUI 的 TextEditor 底层 NSTextView 还有一层 .padding() 控不到的
// 内部内边距（textContainerInset + textContainer.lineFragmentPadding 默认 5），叠 placeholder 时光标/
// 占位/实际文字对不齐。这里把 lineFragmentPadding 归零、textContainerInset 显式设成 (inset,inset)，
// 文字起点完全由 inset 决定——与同值 SwiftUI 内边距、同字号等宽字体的 placeholder 严丝合缝。
private struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    var textColor: NSColor
    var caret: NSColor
    var inset: CGFloat
    var autoFocus: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = textColor
        tv.insertionPointColor = caret
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.textContainerInset = NSSize(width: inset, height: inset)
        tv.textContainer?.lineFragmentPadding = 0
        tv.string = text
        if autoFocus {
            DispatchQueue.main.async { [weak tv] in tv?.window?.makeFirstResponder(tv) }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self   // 让回调里的 binding 始终指向最新的
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }   // 仅在外部值变化时回写，避免打断输入光标
        tv.textColor = textColor
        tv.insertionPointColor = caret
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextEditor
        init(_ parent: PlainTextEditor) { self.parent = parent }
        func textDidChange(_ note: Notification) {
            guard let tv = note.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}

// MARK: - 空状态

private struct EmptyScreen: View {
    let t: Theme
    var dragging: Bool
    @EnvironmentObject var state: AppState
    @State private var showText = false
    var body: some View {
        let ps = permSummary(state.permission, state.lang)
        ScreenFrame(t: t) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ps.eyebrow).font(.sans(11, .bold)).tracking(1.2).foregroundStyle(t.accent)
                    Text("LocalShare").font(.display(28, .semibold)).tracking(-0.3).foregroundStyle(t.ink)
                }
                Spacer()
                IdlePill(t: t, label: L.idle(state.lang), port: state.configuredPort)
                IconButton(t: t, systemImage: "gearshape", help: L.settings(state.lang)) { state.openSettings() }
            }
        } content: {
            VStack(spacing: 0) {
                dropZone
                // 文本入口：与文件并列的平级第二入口（设计语言上「或，分享一段文本」）。
                GhostButton(t: t, title: L.shareTextButton(state.lang), systemImage: "text.alignleft", fullWidth: true) {
                    showText = true
                }
                .padding(.top, 12)
                if state.showRecents {
                    RecentSharesView(t: t, lang: state.lang, items: state.recents.filter { $0.exists },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
                }
            }
        }
        .sheet(isPresented: $showText) { TextEntrySheet(t: t, initial: state.textDraft, isUpdate: false) }
    }

    private var dropZone: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(t.accentSoft)
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "arrow.up.to.line").font(.system(size: 24, weight: .medium)).foregroundStyle(t.accent))
                .padding(.bottom, 14)
            Text(L.dropZoneTitle(state.lang)).font(.sans(15.5, .semibold)).foregroundStyle(t.ink)
            Text(L.dropZoneSub(state.lang)).font(.sans(12.5)).foregroundStyle(t.inkMute).padding(.top, 4)
            PrimaryButton(t: t, title: L.pickAnyButton(state.lang), systemImage: "doc.badge.plus") { state.pickAny() }
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
    @State private var showText = false       // 文本编辑弹层（编辑当前分享的文本）
    private func editText() { showText = true }
    var body: some View {
        let ps = permSummary(state.permission, state.lang)
        ScreenFrame(t: t) {
            HStack(spacing: 8) {
                Text("LocalShare").font(.display(22, .semibold)).tracking(-0.2).foregroundStyle(t.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 8)
                StatusPill(t: t, running: state.isRunning, host: state.selectedInterface?.ip,
                           port: state.isRunning ? state.port : state.configuredPort)
                    .layoutPriority(1)   // IP:端口是数据，缺宽时让品牌标题先缩（它有 minimumScaleFactor），地址不被截断
                IconButton(t: t, systemImage: "gearshape", help: L.settings(state.lang)) { state.openSettings() }
            }
        } content: {
            VStack(spacing: 16) {
                ticket(ps)
                // 文本与文件共存：在票据下补一张「附带文本」小卡（预览 + 编辑）。纯文本分享则文本就是票据本身。
                if state.hasText && !state.isTextOnly { attachedTextCard }
                if !state.received.isEmpty { receivedCard }
                actions
                if state.interfaces.count > 1 { interfacePicker }
                if state.sharedIsFile && state.showRecents {
                    RecentSharesView(t: t, lang: state.lang, items: state.recents.filter { $0.exists && Set($0.paths) != state.currentSharePaths },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) })
                }
            }
        }
        .sheet(isPresented: $showText) { TextEntrySheet(t: t, initial: state.textDraft, isUpdate: true) }
    }

    private func ticket(_ ps: PermSummary) -> some View {
        TicketCard(t: t) {
            if state.isTextOnly { AnyView(textStub(ps)) }
            else if state.isMultiple { AnyView(multipleStub(ps)) }
            else if state.sharedIsFile { AnyView(fileStub(ps)) }
            else { AnyView(folderStub(ps)) }
        } pass: {
            qrPass
        }
    }

    // 纯文本分享的存根：文本图标 + 「正在分享文本」+ 字数 + 前几行预览。
    private func textStub(_ ps: PermSummary) -> some View {
        let lang = state.lang
        let text = state.sharedText ?? ""
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                TextGlyph(t: t, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L.sharingTextKicker(lang)) · \(ps.tag)").font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text(L.webText(lang)).font(.sans(16, .bold)).foregroundStyle(t.ink)
                    Text(LStr.charCount(text.count, lang)).font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t, lang: lang) { state.clearShare() }
            }
            Text(text).font(.mono(11.5)).foregroundStyle(t.inkFaint)
                .lineLimit(3).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { editText() }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // 文本+文件时的「附带文本」卡：单行预览 + 编辑入口（清空再提交即撤下文本，文件保留）。
    private var attachedTextCard: some View {
        let lang = state.lang
        return HStack(spacing: 11) {
            TextGlyph(t: t, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.sharingTextKicker(lang)).font(.sans(11, .bold)).tracking(0.5).foregroundStyle(t.inkMute)
                Text(state.sharedText ?? "").font(.mono(11.5)).foregroundStyle(t.ink)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 6)
            GhostButton(t: t, title: L.editTextButton(lang), systemImage: "pencil") { editText() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 多项存根：叠放印章 + 「正在分享 N 项」+ 文件/文件夹分项概要 + 前几项名称预览。
    private func multipleStub(_ ps: PermSummary) -> some View {
        let items = state.sharedItems
        let lang = state.lang
        let dirCount = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        let fileCount = items.count - dirCount
        var parts: [String] = []
        if fileCount > 0 { parts.append(LStr.fileCount(fileCount, lang)) }
        if dirCount > 0 { parts.append(LStr.folderCount(dirCount, lang)) }
        let preview = items.prefix(3).map(\.lastPathComponent).joined(separator: lang == .zh ? "、" : ", ")
            + (items.count > 3 ? (lang == .zh ? " 等" : " …") : "")
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                MultiGlyph(t: t, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(L.sharingKicker(lang)) · \(ps.tag)").font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text(LStr.itemCount(items.count, lang)).font(.sans(16, .bold)).foregroundStyle(t.ink)
                    Text(parts.joined(separator: " · ")).font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t, lang: lang) { state.clearShare() }
            }
            MultiPreviewMenu(t: t, lang: lang, items: items, preview: preview) { state.revealInFinder($0) }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
    }

    // 单文件存根
    private func fileStub(_ ps: PermSummary) -> some View {
        let url = state.sharedURL ?? URL(fileURLWithPath: "/")
        let cat = FileType.category(of: url, isDir: false)
        let catName = (cat == .other) ? L.fileKind(state.lang) : cat.displayName(state.lang)
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
                ClearButton(t: t, lang: state.lang) { state.clearShare() }
            }
            PathRow(t: t, lang: state.lang, url: url, isFile: true)
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
                    Text("\(L.sharingFolderKicker(state.lang)) · \(ps.tag)").font(.sans(10.5, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                    Text(url.lastPathComponent).font(.sans(16, .bold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                    Text(state.sharedDetail ?? "").font(.mono(11.5)).foregroundStyle(t.inkMute)
                }
                Spacer(minLength: 8)
                ClearButton(t: t, lang: state.lang) { state.clearShare() }
            }
            .padding(.horizontal, 18).padding(.top, 16)
            PathRow(t: t, lang: state.lang, url: url, isFile: false)
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
            HStack(spacing: 6) {
                ForEach(Array(ps.chips.enumerated()), id: \.offset) { i, c in
                    PermChip(t: t, text: c, hot: ps.writable && i > 0)
                }
                Spacer()
                Button { state.openSettings() } label: {
                    Text(L.changePerm(state.lang)).font(.sans(11)).foregroundStyle(t.accent)
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
                Text(L.received(state.lang)).font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                Spacer()
                if state.received.count > 3 {
                    Text(LStr.itemCount(state.received.count, state.lang)).font(.mono(11)).foregroundStyle(t.inkFaint)
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 5)
            ForEach(state.received.prefix(3), id: \.self) { url in
                ReceivedRow(t: t, lang: state.lang, url: url) { state.revealReceived(url) }
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 通行区：QR + 说明 + 复制条
    private var qrPass: some View {
        let running = state.isRunning
        let caption = state.isTextOnly ? L.scanCaptionText(state.lang)
            : (state.isMultiple ? L.scanCaptionMultiple(state.lang)
            : (state.sharedIsFile ? L.scanCaptionFile(state.lang) : L.scanCaptionFolder(state.lang)))
        return VStack(spacing: 0) {
            QRCard(image: state.qrImage, size: 172, dimmed: !running).padding(.top, 22)
            Text(running ? caption : L.broadcastStopped(state.lang)).font(.sans(13, .semibold)).foregroundStyle(t.ink).padding(.top, 14)
            CopyPill(t: t, lang: state.lang, value: state.primaryURL ?? "—",
                     compact: true, onOpen: openInBrowser).padding(.top, 10)
            if let local = state.localURL {
                // 备用地址（主机名 / .local）紧贴主地址、归入卡内，保持内聚。左缩进对齐上方地址文字。
                BackupAddressRow(t: t, lang: state.lang, full: local) {
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
                    ViewerListPopover(t: t, lang: state.lang, viewers: state.viewers)
                }
            }
        }
        .padding(.horizontal, 18).padding(.bottom, 18)
        .animation(.easeInOut(duration: 0.2), value: state.viewerCount > 0)
    }

    // 在线访客摘要：反查到设备名才领衔具名（单台直呼其名、多台「领衔 + 等 N 人」）；
    // 查不到则统一「N 人正在浏览」——不在摘要露 IP 尾号，完整 IP 留给展开列表。
    private var viewerText: String {
        LStr.viewerSummary(name: state.viewers.first?.name, count: state.viewerCount, state.lang)
    }

    @ViewBuilder private var actions: some View {
        if state.isRunning {
            HStack(spacing: 10) {
                // 纯文本分享：主操作是「编辑文本」而非更换文件。
                if state.isTextOnly {
                    GhostButton(t: t, title: L.editTextButton(state.lang),
                                systemImage: "pencil", fullWidth: true) { editText() }
                } else {
                    GhostButton(t: t, title: state.sharedIsFile ? L.replaceFile(state.lang) : L.replace(state.lang),
                                systemImage: "arrow.left.arrow.right", fullWidth: true) { state.pickAny() }
                }
                DangerButton(t: t, title: L.stop(state.lang)) { state.stop() }
            }
        } else {
            HStack(spacing: 10) {
                PrimaryButton(t: t, title: L.rebroadcast(state.lang), systemImage: "play.fill", fullWidth: true) { state.start() }
                GhostButton(t: t, title: L.clear(state.lang)) { state.clearShare() }
            }
        }
    }

    private var interfacePicker: some View {
        Menu {
            ForEach(state.interfaces) { iface in
                Button(iface.displayName(state.lang)) { state.selectInterface(iface) }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                Text(state.selectedInterface?.displayName(state.lang) ?? L.selectSource(state.lang)).font(.mono(11))
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
    let lang: Lang
    let items: [URL]
    let preview: String
    let reveal: (URL) -> Void
    @State private var hover = false
    var body: some View {
        Menu {
            Section(L.revealInFinder(lang)) {
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
        .help(L.revealShareItems(lang))
    }
}

// 收件单行：类型小图标 + 文件名，悬停亮出跳转箭头（点击在 Finder 中显示）。
private struct ReceivedRow: View {
    let t: Theme
    let lang: Lang
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
        .help(L.revealInFinder(lang))
    }
}

// 在线访客明细弹窗：列出全部活跃访客（设备名优先，查不到显示完整 IP），最近活跃在前。
// 仅分享者本机可见——网页端永不外泄身份（见 FileServer.activeViewers）。
private struct ViewerListPopover: View {
    let t: Theme
    let lang: Lang
    let viewers: [ViewerInfo]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(t.ok).frame(width: 6, height: 6)
                Text(L.viewing(lang)).font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                Spacer(minLength: 16)
                Text(LStr.viewerCountLabel(viewers.count, lang)).font(.mono(11)).foregroundStyle(t.inkFaint)
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
                    Text(LStr.elapsed(v.since, lang)).font(.sans(10.5)).foregroundStyle(t.inkFaint)
                        .fixedSize()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
        .frame(width: 230)
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
                IconButton(t: t, systemImage: "gearshape", help: L.settings(state.lang)) { state.openSettings() }
            }
        } content: {
            VStack(spacing: 14) {
                Spacer(minLength: 60)
                Image(systemName: "wifi.slash").font(.system(size: 46)).foregroundStyle(t.inkFaint)
                Text(L.noNetwork(state.lang)).font(.display(21)).foregroundStyle(t.ink)
                Text(L.noNetworkHint(state.lang))
                    .font(.sans(13)).foregroundStyle(t.inkMute)
                    .multilineTextAlignment(.center).lineSpacing(3)
                GhostButton(t: t, title: L.refresh(state.lang), systemImage: "arrow.clockwise") { state.refreshNetwork() }
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
    @EnvironmentObject var updater: UpdaterController
    @State private var portText = ""
    var body: some View {
        // portText 初始为空、onAppear 才填入当前端口；首帧若按空串校验会闪出「无效 + 放弃/应用」行再弹回。
        // 空串一律视作「当前生效端口」，让首帧与落定后一致，消除进入设置页时的这层闪烁。
        let lang = state.lang
        let effectivePort = portText.isEmpty ? String(state.configuredPort) : portText
        let pv = validatePort(effectivePort, lang)
        let pColor = pv.state == .ok ? t.ok : (pv.state == .occupied ? t.warn : t.danger)
        let changed = !portText.isEmpty && (Int(portText) ?? -1) != Int(state.configuredPort)
        let ps = permSummary(state.permission, lang)
        return ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(lang)) { state.goShare() }
                Text(L.shareSettings(lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // MARK: 网络（监听端口 + 可见范围）
                SectionLabel(t: t, text: L.sectionNetwork(lang)).padding(.bottom, 8)

                // 监听端口：IP 前缀 + 端口输入框 + 实时可用性校验。
                HStack(spacing: 10) {
                    Text("\(state.selectedInterface?.ip ?? L.thisMachine(lang)) :").font(.mono(14)).foregroundStyle(t.inkMute)
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
                        Text(pv.state == .ok ? L.portOk(lang) : (pv.state == .occupied ? L.portOccupied(lang) : L.portInvalid(lang)))
                            .font(.sans(11.5, .bold))
                    }
                    .foregroundStyle(pColor)
                }
                .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(pv.state == .ok ? t.line : pColor, lineWidth: 1))

                HStack(alignment: .top, spacing: 8) {
                    Text(pv.state == .ok ? L.portOkHint(lang) : pv.message)
                        .font(.sans(11.5, pv.state == .ok ? .regular : .semibold))
                        .foregroundStyle(pv.state == .ok ? t.inkMute : pColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    if let s = pv.suggest {
                        Button { portText = String(s) } label: {
                            Text(LStr.changeToPort(s, lang)).font(.sans(11.5, .bold)).foregroundStyle(t.accent)
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
                                Text(L.discardChanges(lang)).font(.sans(13, .semibold))
                            }
                            .foregroundStyle(t.inkMute)
                        }
                        .buttonStyle(.plain)
                        if pv.state != .invalid {
                            Button { apply(pv, changed: changed) } label: {
                                Text(L.applyRestart(lang)).font(.sans(13, .semibold)).foregroundStyle(t.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 12)
                }

                // 仅当前网络可见：同属网络设置，紧随端口、以分隔线归组。只有同时连了多个网络时才有意义，
                // 故描述按是否多网卡分两种措辞，避免单网卡时给出空泛的“其它网络”字样。
                settingRow(top: true, title: L.bindOnlyTitle(lang),
                           desc: state.interfaces.count > 1
                                ? L.bindOnlyDescMulti(lang)
                                : L.bindOnlyDescSingle(lang)) {
                    ToggleSwitch(t: t, isOn: state.bindSelectedOnly) { state.setBindSelectedOnly(!state.bindSelectedOnly) }
                }
                .padding(.top, 14)

                // MARK: 访问权限
                HStack {
                    SectionLabel(t: t, text: L.sectionPermission(lang))
                    Spacer()
                    Text("\(L.currentColon(lang))\(ps.tag)").font(.sans(11, .bold))
                        .foregroundStyle(ps.writable ? t.accent : t.inkMute)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(Capsule().fill(ps.writable ? t.accentSoft : .clear))
                        .overlay(Capsule().strokeBorder(ps.writable ? .clear : t.line, lineWidth: 1))
                }
                .padding(.top, 24).padding(.bottom, 4)

                permRow(name: L.permReadName(lang), desc: L.permReadDesc(lang), locked: true, on: true)
                permRow(name: L.permUploadName(lang),
                        desc: state.canToggleUpload ? L.permUploadDescOn(lang) : L.permUploadDescOff(lang),
                        locked: !state.canToggleUpload,
                        on: state.permission.add, top: true) {
                    state.setUploadAllowed(!state.permission.add)
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(t.accent).padding(.top, 1)
                    Text(ps.writable ? L.permInfoWritable(lang) : L.permInfoReadonly(lang))
                        .font(.sans(11.5)).foregroundStyle(t.dark ? t.ink : Color(hex: 0x8a3a1e)).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accentSoft))
                .padding(.top, 12)

                // 明文传输提示：纯 LAN 不加密，公共网络下同网的人能看到内容。用克制的灰字、不进彩底警告框。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open").font(.system(size: 13)).foregroundStyle(t.inkMute).padding(.top, 1)
                    Text(L.plaintextWarning(lang))
                        .font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                // MARK: 外观
                SectionLabel(t: t, text: L.sectionAppearance(lang)).padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 8) {
                    appearanceSeg(L.appearanceFollow(lang), .system)
                    appearanceSeg(L.appearanceLight(lang), .light)
                    appearanceSeg(L.appearanceDark(lang), .dark)
                }

                // MARK: 语言
                SectionLabel(t: t, text: L.sectionLanguage(lang)).padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 8) {
                    langSeg(L.langFollow(lang), .system)
                    langSeg("中文", .zh)        // 语言名用本族文字，不翻译
                    langSeg("English", .en)
                }

                // MARK: 主界面（最近分享展示 + 窗口尺寸）
                SectionLabel(t: t, text: L.sectionMain(lang)).padding(.top, 24).padding(.bottom, 4)
                settingRow(title: L.showRecentsTitle(lang), desc: L.showRecentsDesc(lang)) {
                    ToggleSwitch(t: t, isOn: state.showRecents) { state.setShowRecents(!state.showRecents) }
                }
                settingRow(top: true, title: L.rememberTextTitle(lang), desc: L.rememberTextDesc(lang)) {
                    ToggleSwitch(t: t, isOn: state.persistText) { state.setPersistText(!state.persistText) }
                }
                settingRow(top: true, title: L.resetWindowTitle(lang)) {
                    GhostButton(t: t, title: L.resetDefault(lang), systemImage: "arrow.counterclockwise") {
                        state.resetWindowSize()
                    }
                }

                // MARK: 更新
                // 始终展示这一组：开关留在设置里，用户才能确认「自动更新」这个功能确实存在。
                // dev / 未签名构建里 updater 未启动（占位 EdDSA 公钥），此时只把开关置灰、并改说明文案
                // 点明原因——是「此构建未启用」而非把整段藏掉。isActive 只决定可用态，不决定是否渲染。
                SectionLabel(t: t, text: L.sectionUpdate(lang)).padding(.top, 24).padding(.bottom, 4)
                settingRow(title: L.autoUpdate(lang),
                           desc: updater.isActive
                                ? L.autoUpdateDescOn(lang)
                                : L.autoUpdateDescOff(lang)) {
                    ToggleSwitch(t: t, isOn: updater.automaticChecks, locked: !updater.isActive) {
                        updater.setAutomaticChecks(!updater.automaticChecks)
                    }
                }

                // MARK: 命令行工具
                // 裸二进制（swift run）没有 .app 可指：不给安装按钮，状态/卸载照常。
                SectionLabel(t: t, text: L.sectionCLI(lang)).padding(.top, 24).padding(.bottom, 8)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("localshare").font(.mono(13.5, .bold)).foregroundStyle(t.ink)
                        Text(cliHint).font(.sans(11.5)).foregroundStyle(t.inkMute)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if state.cliStatus != .notInstalled {
                        Button { state.uninstallCLI() } label: {
                            Text(L.uninstall(lang)).font(.sans(13, .semibold)).foregroundStyle(t.inkMute)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                    }
                    if state.cliStatus == .installed {
                        HStack(spacing: 5) {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                            Text(L.installed(lang)).font(.sans(11.5, .bold))
                        }
                        .foregroundStyle(t.ok)
                    } else if CLIInstaller.binaryPath() != nil {
                        GhostButton(t: t,
                                    title: state.cliStatus == .notInstalled ? L.install(lang) : L.reinstall(lang),
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
            return CLIInstaller.binaryPath() != nil ? L.cliHintAvailable(state.lang) : L.cliHintUnavailable(state.lang)
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

    // 语言分段：结构同 appearanceSeg，绑 langPref / setLangPref。
    private func langSeg(_ label: String, _ pref: LangPref) -> some View {
        let on = state.langPref == pref
        return Button { state.setLangPref(pref) } label: {
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
                    if locked && action == nil { Text(L.alwaysOn(state.lang)).font(.sans(11)).foregroundStyle(t.inkFaint) }
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
                IconButton(t: t, systemImage: "chevron.left", help: L.back(state.lang)) { state.goShare() }
                Text(L.shareHistory(state.lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                if !state.recents.isEmpty {
                    Button { state.clearRecents() } label: {
                        Text(L.clearAll(state.lang)).font(.sans(12)).foregroundStyle(t.inkMute)
                    }.buttonStyle(.plain)
                }
            }
        } content: {
            if state.recents.isEmpty {
                VStack(spacing: 8) {
                    Spacer(minLength: 80)
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 38)).foregroundStyle(t.inkFaint)
                    Text(L.noHistory(state.lang)).font(.sans(14, .semibold)).foregroundStyle(t.inkMute)
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
                    Text(h.displayName(state.lang)).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                    if live {
                        HStack(spacing: 4) {
                            StatusDot(color: t.accent, live: true, size: 5)
                            Text(L.live(state.lang)).font(.sans(10.5, .bold)).foregroundStyle(t.accent)
                        }
                    }
                }
                Text("\(h.detail) · \(LStr.friendlyDate(h.date, state.lang))").font(.mono(11.5)).foregroundStyle(t.inkMute)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if live {
                DangerButton(t: t, title: L.stop(state.lang)) { state.stop() }
            } else {
                GhostButton(t: t, title: L.reshare(state.lang), systemImage: "arrow.left.arrow.right") { state.reshare(h) }
            }
            // 逐条删除（文本/文件一视同仁）：只动历史，不影响正在直播的分享。
            IconButton(t: t, systemImage: "trash", help: L.deleteEntry(state.lang)) { state.deleteRecent(h) }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }
}

// MARK: - 最近分享模块（空状态 + 单文件分享复用）

private struct RecentSharesView: View {
    let t: Theme
    let lang: Lang
    var items: [RecentShare]
    var onAll: () -> Void
    var onReshare: (RecentShare) -> Void
    var body: some View {
        if items.isEmpty {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                HStack {
                    SectionLabel(t: t, text: L.sectionRecent(lang))
                    Spacer()
                    Button { onAll() } label: { Text(L.viewAll(lang)).font(.sans(12)).foregroundStyle(t.accent) }
                        .buttonStyle(.plain)
                }
                .padding(.bottom, 6)
                ForEach(Array(items.prefix(2).enumerated()), id: \.element.id) { i, h in
                    HStack(spacing: 11) {
                        RecentGlyph(t: t, item: h, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(h.displayName(lang)).font(.sans(13, .semibold)).foregroundStyle(t.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text(LStr.friendlyDate(h.date, lang)).font(.mono(11)).foregroundStyle(t.inkMute)
                        }
                        Spacer(minLength: 4)
                        GhostButton(t: t, title: L.reshare(lang), systemImage: "arrow.left.arrow.right") { onReshare(h) }
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
        if item.isText {
            TextGlyph(t: t, size: size)
        } else if item.isMultiple {
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
    @EnvironmentObject var state: AppState
    @State private var show = false
    var body: some View {
        let lang = state.lang
        return HStack {
            Button { show.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").font(.system(size: 12))
                    Text(L.cantConnect(lang)).font(.sans(12.5, .medium))
                }
                .foregroundStyle(t.inkMute)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $show, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 11) {
                    Text(L.cantConnectTitle(lang)).font(.sans(12, .semibold)).foregroundStyle(t.ink)
                    row("1", L.help1(lang))
                    row("2", L.help2(lang))
                    row("3", L.help3(lang))
                    Rectangle().fill(t.line).frame(height: 1).padding(.vertical, 1)
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "lock.open").font(.system(size: 11)).foregroundStyle(t.inkMute).frame(width: 16)
                        Text(L.helpPlaintext(lang))
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
