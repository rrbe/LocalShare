import AppKit
import SwiftUI

// 入口：默认跑 SwiftUI GUI；设 LFS_HEADLESS=1 时只起服务（供测试/自动化，无窗口）。
@main
enum EntryPoint {
    static func main() {
        if ProcessInfo.processInfo.environment["LFS_HEADLESS"] == "1" {
            HeadlessServer.run()
        } else {
            LanFileShareApp.main()
        }
    }
}

struct LanFileShareApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        Window("LocalShare", id: "main") {
            ContentView().environmentObject(state)
        }
        .windowStyle(.hiddenTitleBar) // 全幅出血：纸张背景铺到顶，红绿灯浮于内容之上
        .defaultSize(width: 500, height: 720) // 钉死初始尺寸（否则贪婪背景会把窗口撑得过宽）
        .windowResizability(.contentMinSize)
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
