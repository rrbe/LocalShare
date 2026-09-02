import SwiftUI
import AppKit

// 收件单行：类型小图标 + 文件名，悬停亮出跳转箭头（点击在 Finder 中显示）。
struct ReceivedRow: View {
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

// 收件箱卡片（收文本 v2）：手机投递来的文本，新→旧。每条带来源（设备名 / IP）+ 收到时长 + 正文预览，
// 单条复制 / 删除，整卡清空（二次确认）。复用「新收到」卡片视觉语言。未读角标随到达累加，进入本卡即清。
struct ReceivedTextsCard: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var confirmClear = false
    var body: some View {
        let lang = state.lang
        let items = state.receivedTexts
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(t.accent).frame(width: 6, height: 6)
                Text(L.receivedTextsTitle(lang)).font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                if state.unreadReceived > 0 {
                    Text(LStr.unreadCount(state.unreadReceived, lang)).font(.sans(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(t.accent))
                }
                Spacer()
                if !items.isEmpty {
                    Button { confirmClear = true } label: {
                        Text(L.clearAll(lang)).font(.sans(11)).foregroundStyle(t.inkMute)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(L.clearReceivedConfirm(lang), isPresented: $confirmClear, titleVisibility: .visible) {
                        Button(L.clearAll(lang), role: .destructive) { state.clearReceivedTexts() }
                        Button(L.cancel(lang), role: .cancel) {}
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 5)

            if items.isEmpty {
                // 只收模式空收件箱：一句等待提示，避免空卡突兀。
                Text(L.inboxWaiting(lang)).font(.sans(12)).foregroundStyle(t.inkFaint)
                    .padding(.horizontal, 16).padding(.bottom, 12)
            } else {
                ForEach(Array(items.prefix(12))) { rt in
                    ReceivedTextRow(t: t, lang: lang, item: rt,
                                    onCopy: { state.copyReceivedText(rt) },
                                    onDelete: { state.deleteReceivedText(rt) })
                }
                if items.count > 12 {
                    Text(LStr.receivedCount(items.count, lang)).font(.mono(11)).foregroundStyle(t.inkFaint)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.horizontal, 16).padding(.top, 4)
                }
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
        .onAppear { state.markReceivedRead() }   // 看到收件箱即视作已读
    }
}

// 收件箱单行：左小图标 + 来源/时长 + 正文预览（最多 3 行，可选中），右侧复制（成功闪 ✓）+ 删除。
struct ReceivedTextRow: View {
    let t: Theme
    let lang: Lang
    let item: ReceivedText
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            TextGlyph(t: t, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.source).font(.sans(11.5, .semibold)).foregroundStyle(t.inkMute)
                        .lineLimit(1).truncationMode(.middle)
                    Text("·").font(.sans(10)).foregroundStyle(t.inkFaint)
                    Text(LStr.elapsed(item.date, lang)).font(.mono(10.5)).foregroundStyle(t.inkFaint).fixedSize()
                    Spacer(minLength: 0)
                }
                Text(item.text).font(.mono(11.5)).foregroundStyle(t.ink)
                    .lineLimit(3).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            VStack(spacing: 2) {
                Button {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(copied ? t.ok : (hover ? t.ink : t.inkFaint))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(hover && !copied ? t.surfaceAlt : .clear))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).help(L.copyTextAction(lang))
                ClearButton(t: t, lang: lang, help: L.deleteEntry(lang)) { onDelete() }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7)
        .onHover { hover = $0 }
    }
}
// MARK: - 传递文本二级页（收/发合一）

// 一页一码：上半发文本（编辑器 + 发送/更新/撤回），中间一个二维码恒指 /ls/text，下半是「允许收文本」
// 开关 + 收件箱。手机扫这一个码即可读取电脑文本并（开关开着时）发回文本——双向都在这页。
struct TextScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var draft = ""
    var body: some View {
        let lang = state.lang
        ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(lang)) { state.goShare() }
                Text(L.transferText(lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                WideLayoutButton(t: t)
                IconButton(t: t, systemImage: "gearshape", help: L.settings(lang)) { state.openSettings() }
            }
        } content: {
            VStack(spacing: 16) {
                if state.isRunning, state.qrImage != nil {
                    qrCard
                } else if !state.hasNetwork {
                    noNetworkHint
                }
                composeCard
                receiveRow
                if state.textInboxEnabled || !state.receivedTexts.isEmpty { ReceivedTextsCard(t: t) }
                // 正在传递（发文本或收文本）才出「停止」：一步撤文本+关接收+停服务+回选择页，
                // 对齐文件票据的「停止」。只是编辑没发、也没开接收时无可停，靠 ← 返回即可。
                if state.isRunning && (state.hasText || state.textInboxEnabled) {
                    HStack {
                        Spacer()
                        DangerButton(t: t, title: L.stop(state.lang)) { state.stopTextTransfer() }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
            }
        }
        .onAppear { draft = state.sharedText ?? state.textDraft }
    }

    // 发文本：编辑器 + 发送/更新（与当前广播一致时置灰）；已在广播则可「撤回」（撤下文本，文件不受影响）。
    private var composeCard: some View {
        let lang = state.lang
        let blank = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let unchanged = draft == (state.sharedText ?? "")
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Text(L.sendTextKicker(lang)).font(.sans(11, .bold)).tracking(0.8).foregroundStyle(t.inkMute)
                Spacer()
                if state.hasText {
                    Button { state.setSharedText(nil); draft = "" } label: {
                        Text(L.retract(lang)).font(.sans(11)).foregroundStyle(t.inkMute)
                    }.buttonStyle(.plain)
                }
            }
            PlainTextEditor(text: $draft, placeholder: L.textEditorPlaceholder(lang),
                            placeholderColor: NSColor(t.inkFaint), textColor: NSColor(t.ink),
                            caret: NSColor(t.accent), inset: 10, autoFocus: false)
                .frame(minHeight: 118)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line, lineWidth: 1))
            PrimaryButton(t: t, title: state.hasText ? L.textUpdateAction(lang) : L.textShareAction(lang),
                          systemImage: "paperplane.fill", fullWidth: true) {
                state.setSharedText(draft)
            }
            .disabled(blank || unchanged)
            .opacity(blank || unchanged ? 0.5 : 1)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 二维码恒指 /ls/text；收发共用一句说明，具体能力由页面上的内容与开关表达。
    private var qrCard: some View {
        let lang = state.lang
        return VStack(spacing: 0) {
            QRCard(image: state.qrImage, size: 172, dimmed: !state.isRunning).padding(.top, 4)
            Text(L.scanCaptionTransfer(lang)).font(.sans(13, .semibold)).foregroundStyle(t.ink).padding(.top, 14)
            CopyPill(t: t, lang: lang, value: state.presentedURL ?? "—", compact: true, onOpen: openInBrowser).padding(.top, 10)
            if let code = state.presentedAccessCode {
                AccessCodePill(t: t, lang: lang, value: code).padding(.top, 7)
            }
            if !state.otherAddresses.isEmpty {
                OtherAddressesDisclosure(t: t, lang: lang, addresses: state.otherAddresses)
                    .padding(.top, 7)
            }
            AccessModeButton(t: t, lang: lang, usingAccessCode: state.accessCodeEnabled) {
                state.setAccessCodeEnabled(!state.accessCodeEnabled)
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18).padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 无网络时保留恢复提示；联网但尚未开始传递时直接呈现可执行的发送与接收控件。
    private var noNetworkHint: some View {
        let lang = state.lang
        return VStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(t.inkFaint)
            Text(L.noNetwork(lang))
                .font(.sans(12.5)).foregroundStyle(t.inkMute)
                .multilineTextAlignment(.center).lineSpacing(2)
        }
        .frame(maxWidth: .infinity).padding(.horizontal, 20).padding(.vertical, 34)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 接收文本：默认关的小开关（与设置页同一闸门 textInboxEnabled）。开了二维码页就挂出发送框、下面长出收件箱。
    private var receiveRow: some View {
        let lang = state.lang
        return HStack(spacing: 12) {
            Text(L.recvInboxTitle(lang)).font(.sans(13, .semibold)).foregroundStyle(t.ink)
            Spacer(minLength: 8)
            ToggleSwitch(t: t, isOn: state.textInboxEnabled) { state.setTextInboxEnabled(!state.textInboxEnabled) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    private func openInBrowser() {
        guard let s = state.presentedURL, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }
}
