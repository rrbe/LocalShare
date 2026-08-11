import SwiftUI

// MARK: - 分享历史

struct HistoryScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @State private var confirmClear = false   // 「清空全部」是批量销毁，需二次确认（单条 ✕ 不需要）
    var body: some View {
        ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(state.lang)) { state.goShare() }
                Text(L.shareHistory(state.lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                if !state.recents.isEmpty {
                    Button { confirmClear = true } label: {
                        Text(L.clearAll(state.lang)).font(.sans(12)).foregroundStyle(t.inkMute)
                    }.buttonStyle(.plain)
                    .confirmationDialog(L.clearAllConfirm(state.lang), isPresented: $confirmClear, titleVisibility: .visible) {
                        Button(L.clearAll(state.lang), role: .destructive) { state.clearRecents() }
                        Button(L.cancel(state.lang), role: .cancel) {}
                    }
                }
                WideLayoutButton(t: t)
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
            // 逐条删除（文本/文件一视同仁）：同款 ✕，只动历史、不影响正在直播的分享。
            ClearButton(t: t, lang: state.lang, help: L.deleteEntry(state.lang)) { state.deleteRecent(h) }
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }
}

// MARK: - 最近分享模块（空状态 + 单文件分享复用）

struct RecentSharesView: View {
    let t: Theme
    let lang: Lang
    var items: [RecentShare]
    var onAll: () -> Void
    var onReshare: (RecentShare) -> Void
    var onDelete: (RecentShare) -> Void
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
                        ClearButton(t: t, lang: lang, help: L.deleteEntry(lang)) { onDelete(h) }
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
struct RecentGlyph: View {
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
