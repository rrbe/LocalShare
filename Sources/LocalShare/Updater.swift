import Combine
import Sparkle
import SwiftUI

// Sparkle 自动更新封装。
//
// 设计要点：
// - 仅在 GUI 路径（LocalShareApp）构造；headless 模式（LS_HEADLESS=1）完全不碰，
//   测试/自动化既不起 updater、也不弹任何窗口。
// - `startingUpdater: true` 让 Sparkle 启动后按 Info.plist 的 SUEnableAutomaticChecks /
//   SUScheduledCheckInterval 自动后台检查；发现新版会弹原生提示让用户确认安装
//   （SUAutomaticallyUpdate=false，不静默安装）。
// - 信任链走 EdDSA：更新包由私钥签名、app 内嵌 SUPublicEDKey 校验，与 ad-hoc 代码签名无关，
//   因此未公证也能安全自更新（见 PLAN.md「自动更新」一节）。
//
// 配置（含 SUFeedURL / SUPublicEDKey）全部放在 bundle/Info.plist，这里不硬编码。
@MainActor
final class UpdaterController: ObservableObject {
    private let controller: SPUStandardUpdaterController

    // 绑定到菜单项的可用态：Sparkle 正在检查时为 false，置灰「检查更新…」避免重复触发。
    @Published var canCheckForUpdates = false

    // 后台自动检查开关：反映 / 驱动 Sparkle 的 automaticallyChecksForUpdates。Info.plist 的
    // SUEnableAutomaticChecks 只是首次默认值，用户在设置页关掉后即不再定时检查、不再自动弹更新框
    //（菜单「检查更新…」仍可手动查）。设置写入 UserDefaults，覆盖 Info.plist 默认。
    @Published var automaticChecks = true

    init() {
        // 一律启动 updater：不按构建是否签名 / 配齐做预判。配置缺失（如裸 swift build 无 Info.plist）
        // 顶多让 Sparkle 自己报错，到时再处理，不靠环境判定提前把更新设置藏掉。
        // delegate 暂时为 nil：默认行为（读 Info.plist 配置、标准更新 UI）已满足需求。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
        automaticChecks = controller.updater.automaticallyChecksForUpdates
    }

    // 用户在菜单主动点「检查更新…」时调用；走带 UI 的检查（无更新也会有反馈）。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    // 开 / 关后台自动检查。关掉即不再定时检查、不再自动弹更新框。
    func setAutomaticChecks(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
        automaticChecks = on
    }
}

// 应用菜单里的「检查更新…」项。Sparkle 检查进行中时自动置灰。
struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("检查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
