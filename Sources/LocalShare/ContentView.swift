import SwiftUI
import AppKit
import UniformTypeIdentifiers

// 单窗口 UI（票据风）。权威规范见 DESIGN.md。窗口为无边框工具窗（红绿灯浮于内容左上），
// 内容收成约 420 宽的竖列，顶部留 40 给红绿灯。屏幕路由：主页 / 文件票据 / 传递文本 / 设置 / 历史——
// 文件票据与传递文本同为带返回的二级页；主页在文件后台续跑时挂「正在分享」横幅一键回票据。
// 主题随系统浅深切换（Theme.make）。
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
            // 功能主页（launchpad）：拖拽/选择分享文件、传递文本入口、最近分享。文件分享在后台续跑时
            // 顶部出「正在分享」横幅一键回票据（见 HomeScreen）。文件票据本身是独立二级页 .file。
            HomeScreen(t: t, dragging: isDropTargeted)
        case .file:
            // 文件二维码票据（二级页，带返回）。无网络时换未接入网络页（同样带返回）。
            if state.hasNetwork { ShareScreen(t: t) } else { NoNetworkScreen(t: t) }
        case .text:
            TextScreen(t: t)
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
