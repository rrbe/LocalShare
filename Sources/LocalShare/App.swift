import AppKit
import SwiftUI

// 入口三层分流：LS_HEADLESS=1 只起服务（供测试/自动化）；argv 命中命令行调用
// （`localshare <路径>…` / --headless）走 CLI；否则跑 SwiftUI GUI。
@main
enum EntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["LS_HEADLESS"] == "1" {
            HeadlessServer.run()
        } else if let mode = CLI.parse(CommandLine.arguments) {
            CLI.run(mode)
        } else {
            // 关闭 macOS 窗口状态恢复：干净启动且无可恢复状态时，SwiftUI 的 Window 场景会偶发
            // 不创建窗口（表现为「app 在 Dock 里却没有窗口、双击无响应」）。必须在 NSApplication
            // 启动前同步写入，AppKit 早期读取该标志才生效。
            CFPreferencesSetAppValue("ApplePersistenceIgnoreState" as CFString, kCFBooleanTrue, kCFPreferencesCurrentApplication)
            CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            LocalShareApp.main()
        }
    }
}

struct LocalShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    // Sparkle 自动更新：随 GUI 启动起 updater，按 Info.plist 配置后台检查。headless 不构造。
    @StateObject private var updater = UpdaterController()

    var body: some Scene {
        Window("LocalShare", id: "main") {
            ContentView().environmentObject(state).environmentObject(updater)
        }
        .windowStyle(.hiddenTitleBar) // 全幅出血：暖底铺到顶，红绿灯浮于内容之上
        // 票据风竖窗（设计稿 400×720）。数字与「恢复默认尺寸」共用 AppState 的常量。
        .defaultSize(width: AppState.defaultWindowWidth, height: AppState.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            // 「检查更新…」放进应用菜单的 About 下方，与系统 app 惯例一致。
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // 设置入口移到 macOS 应用菜单（About 下方那一格），标准 ⌘, 打开应用内「分享设置」屏。
            CommandGroup(replacing: .appSettings) {
                Button(L.settings(Lang.current) + "…") { state.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        // 菜单栏常驻图标：关窗后 app（与分享服务）继续活着，从这里唤回窗口或彻底退出。
        // label 视图常驻菜单栏（主窗关闭后唯一活着的 SwiftUI 环境），借它监听唤窗通知
        // 拿 openWindow 重建窗口——CLI 转发的 open 事件靠这条链在「只剩菜单栏」时弹回主窗。
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarIcon()
        }
    }
}

// 菜单栏图标本体：声明 openWindow 环境并监听唤窗通知。
private struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "qrcode")
            .onReceive(NotificationCenter.default.publisher(for: .lsShowMainWindow)) { _ in
                showMainWindow(openWindow)
            }
    }
}

extension Notification.Name {
    // AppState 等无法触达 openWindow 的地方用它请求唤回主窗。
    static let lsShowMainWindow = Notification.Name("lsShowMainWindow")
}

// 唤回主窗口：激活 app、重建已关闭的窗口、唤回最小化的窗口。
@MainActor func showMainWindow(_ openWindow: OpenWindowAction) {
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: "main")
    for window in NSApp.windows where window.isMiniaturized {
        window.deminiaturize(nil)
    }
}

private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L.showLocalShare(Lang.current)) { showMainWindow(openWindow) }
        Divider()
        Button(L.quit(Lang.current)) { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // open 事件可能早于 AppState 构造（@StateObject 时机由 SwiftUI 决定），先缓冲，
    // AppState.init 末尾消费——否则 CLI 冷启动会偶发丢掉首次分享。
    static var pendingOpenURLs: [URL] = []

    // 即使以裸二进制（swift run）启动也强制前台并激活，确保窗口可见。
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 关窗不退出：菜单栏图标常驻，服务继续广播；退出走菜单栏「退出」或 ⌘Q。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // CLI / Share Extension 转发（NSWorkspace open）落地处：换分享项并唤回窗口。
    func application(_ application: NSApplication, open urls: [URL]) {
        openSharedURLs(urls)
    }

    // 声明 CFBundleDocumentTypes 后，LaunchServices 可能走传统文稿打开回调。
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openSharedURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        openSharedURLs([URL(fileURLWithPath: filename)])
        return true
    }

    private func openSharedURLs(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        if let state = AppState.shared {
            state.setShared(existing)
            state.showMainWindow()
        } else {
            Self.pendingOpenURLs += existing
        }
    }
}
