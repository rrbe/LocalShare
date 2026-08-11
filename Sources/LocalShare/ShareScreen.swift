import SwiftUI
import AppKit

// MARK: - 分享屏（单文件 / 文件夹票据）

struct ShareScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var showViewers = false   // 在线访客明细弹窗（点摘要行展开）
    @State private var showText = false       // 文本编辑弹层（编辑当前分享的文本）
    private func editText() { showText = true }
    var body: some View {
        let ps = permSummary(state.permission, state.lang)
        ScreenFrame(t: t) {
            // 二级页头部，与传递文本页同款：← 返回主页 + 标题 +齿轮。运行态/地址在票据正文（QR 说明 +
            // CopyPill）已具，头部不再堆 StatusPill，避免与正文重复、并与 TextScreen 一致。
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(state.lang)) { state.goShare() }
                Text(L.shareFileTitle(state.lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                WideLayoutButton(t: t)
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
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) },
                                     onDelete: { state.deleteRecent($0) })
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
struct MultiPreviewMenu: View {
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
// 在线访客明细弹窗：列出全部活跃访客（设备名优先，查不到显示完整 IP），最近活跃在前。
// 仅分享者本机可见——网页端永不外泄身份（见 FileServer.activeViewers）。
struct ViewerListPopover: View {
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
