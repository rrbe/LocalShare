import SwiftUI

// MARK: - 未接入局域网

struct NoNetworkScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    var body: some View {
        ScreenFrame(t: t) {
            // 现挂在文件票据二级页（.file）下，带 ← 返回主页，免得无网络时卡死在此页。
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(state.lang)) { state.goShare() }
                Text(L.shareFileTitle(state.lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                WideLayoutButton(t: t)
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
