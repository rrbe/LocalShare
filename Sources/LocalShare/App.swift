import AppKit
import SwiftUI

// 入口：默认跑 SwiftUI GUI；设 LS_HEADLESS=1 时只起服务（供测试/自动化，无窗口）。
@main
enum EntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["LS_HEADLESS"] == "1" {
            HeadlessServer.run()
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
            ContentView().environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar) // 全幅出血：暖底铺到顶，红绿灯浮于内容之上
        .defaultSize(width: 410, height: 720) // 票据风竖窗（设计稿 400×720）
        .windowResizability(.contentMinSize)
        .commands {
            // 「检查更新…」放进应用菜单的 About 下方，与系统 app 惯例一致。
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updater)
            }
            // 设置入口移到 macOS 应用菜单（About 下方那一格），标准 ⌘, 打开应用内「分享设置」屏。
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { state.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // 即使以裸二进制（swift run）启动也强制前台并激活，确保窗口可见。
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // 关闭窗口即退出，进而停止服务（避免后台残留监听端口）。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
