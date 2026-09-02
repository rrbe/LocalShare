import SwiftUI

// MARK: - 空状态

struct HomeScreen: View {
    let t: Theme
    var dragging: Bool
    @EnvironmentObject var state: AppState
    // 横幅标题：单项=文件/夹名（中段截断），多选=「N 项」（与票据 multipleStub 标题一致）。
    private var activeShareName: String {
        state.isMultiple ? LStr.itemCount(state.sharedItems.count, state.lang)
                         : (state.sharedURL?.lastPathComponent ?? "")
    }
    // 「传递文本」入口的呼吸点只该表「文本在后台续跑」，故精确判文本态——而非笼统的 isRunning
    //（现在主页可能正跑着文件分享，那不该让文本入口误亮）。
    private var textActive: Bool { state.isRunning && (state.hasText || state.textInboxEnabled) }
    var body: some View {
        let ps = permSummary(state.permission, state.lang)
        ScreenFrame(t: t) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ps.eyebrow).font(.sans(11, .bold)).tracking(1.2).foregroundStyle(t.accent)
                    Text("LocalShare").font(.display(28, .semibold)).tracking(-0.3).foregroundStyle(t.ink)
                }
                Spacer()
                WideLayoutButton(t: t)
                IconButton(t: t, systemImage: "gearshape", help: L.settings(state.lang)) { state.openSettings() }
            }
        } content: {
            VStack(spacing: 0) {
                // 文件分享在后台续跑、用户退回主页时，顶部出可点横幅一键回票据；停止未清除也显（静默态）。
                if !state.sharedItems.isEmpty {
                    ActiveShareBanner(t: t, lang: state.lang, name: activeShareName,
                                      running: state.isRunning, viewers: state.viewerCount) { state.enterFile() }
                        .padding(.bottom, 12)
                }
                dropZone
                // 平级第二入口：传递文本（收/发合一）。点进独立二级页，主页只负责选功能、不就地干活。
                // 收件箱有未读时角标提示；文本在后台续跑时缀呼吸点（见 textActive）。
                TransferTextButton(t: t, lang: state.lang, active: textActive,
                                   unread: state.unreadReceived) { state.openText() }
                    .padding(.top, 12)
                if state.showRecents {
                    RecentSharesView(t: t, lang: state.lang, items: state.recents.filter { $0.exists },
                                     onAll: { state.openHistory() }, onReshare: { state.reshare($0) },
                                     onDelete: { state.deleteRecent($0) })
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
            Text(L.dropZoneTitle(state.lang)).font(.sans(15.5, .semibold)).foregroundStyle(t.ink)
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
// 主页「传递文本」入口：平级第二功能，点进 .text 二级页（收/发合一）。收件箱有未读时数字角标提示、
// 接收开着时缀一个缓慢呼吸的红点——让「正在接收」与「有新文本」在选择页一眼可见，无须把内容堆到主页。
struct TransferTextButton: View {
    let t: Theme
    let lang: Lang
    let active: Bool   // 接收正开着
    let unread: Int
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").font(.system(size: 14, weight: .medium))
                Text(L.transferText(lang)).font(.sans(13.5, .semibold))
                // 未读 → 静态红色数字角标（看一眼收件箱即清）；接收开着但无未读 → 缓慢呼吸的红点，
                // 用淡入淡出表明是"实时接收中"而非静态未读警报，与数字角标天然区分。
                if unread > 0 {
                    Text(LStr.unreadCount(unread, lang)).font(.sans(10, .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(t.accent))
                } else if active {
                    PulsingDot(color: t.accent)
                }
            }
            .foregroundStyle(t.ink)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? t.surfaceAlt : t.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hover ? t.lineStrong : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}

// 主页「正在分享」横幅：文件分享在后台续跑、用户却退回主页时，用一条紧凑可点的横幅如实呈现——
// 点按回到文件票据（.file）看二维码。运行中缀呼吸点 + 在线人数；停止未清除时静默（无呼吸点）。
// 与 TransferTextButton 同手法，但承载更多信息故略高；前导 qrcode 图标暗示「点这里回到码」，
// 配尾部 chevron 即足以表达「可点回去」，不另加文案（强约束：能用设计语言暗示就不堆字）。
struct ActiveShareBanner: View {
    let t: Theme
    let lang: Lang
    let name: String     // 单项=文件/夹名；多选=「N 项」
    let running: Bool
    let viewers: Int
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "qrcode").font(.system(size: 16, weight: .medium)).foregroundStyle(t.accent)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(L.sharingKicker(lang)).font(.sans(10.5, .bold)).tracking(0.6).foregroundStyle(t.inkMute)
                        if running { PulsingDot(color: t.ok) }
                        if running && viewers > 0 {
                            Text(LStr.viewerCountLabel(viewers, lang)).font(.sans(10.5)).foregroundStyle(t.inkMute)
                        }
                    }
                    Text(name).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(t.inkFaint)
            }
            .padding(.horizontal, 14).frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? t.surfaceAlt : t.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hover ? t.lineStrong : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }
    }
}
