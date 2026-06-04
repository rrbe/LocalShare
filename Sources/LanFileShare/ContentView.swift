import SwiftUI

// 单窗口 UI：二维码居中，下面是 URL / 文件夹 / 接口下拉 / 排错提示。
// 三种状态：未选文件夹、无 WiFi、正常运行。
struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            content
            Spacer(minLength: 0)
            footer
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 600)
    }

    // MARK: - 顶部

    private var header: some View {
        HStack {
            Text("📂 局域网文件分享").font(.headline)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(state.isRunning ? "运行中 · 端口 \(state.port)" : "已停止")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 主体（按状态切换）

    @ViewBuilder private var content: some View {
        if state.folderURL == nil {
            emptyFolderState
        } else if !state.hasNetwork {
            noNetworkState
        } else {
            runningState
        }
    }

    private var emptyFolderState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("🗂").font(.system(size: 56))
            Text("选择一个文件夹开始分享").font(.title3)
            Text("同事用手机扫码即可在浏览器里浏览其中的文件。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("选择文件夹…") { state.pickFolder() }
                .controlSize(.large).buttonStyle(.borderedProminent)
            Spacer()
        }
    }

    private var noNetworkState: some View {
        VStack(spacing: 14) {
            Spacer()
            Text("📶").font(.system(size: 56))
            Text("未检测到局域网").font(.title3)
            Text("请先把这台 Mac 连接到与手机相同的 WiFi，再点下方刷新。")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("刷新网络") { state.refreshNetwork() }
                .controlSize(.large)
            Spacer()
        }
    }

    private var runningState: some View {
        VStack(spacing: 14) {
            if let qr = state.qrImage {
                Image(nsImage: qr)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 240, height: 240)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(radius: 1)
            }

            if let url = state.primaryURL {
                VStack(spacing: 4) {
                    Text("手机扫码，或在浏览器打开：").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text(url).font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                        Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("复制链接")
                        Button { open(url) } label: { Image(systemName: "safari") }
                            .buttonStyle(.borderless).help("在本机浏览器打开（自测）")
                    }
                }
            }

            if state.interfaces.count > 1 {
                Picker("网络接口", selection: Binding(
                    get: { state.selectedInterface },
                    set: { state.selectedInterface = $0 }
                )) {
                    ForEach(state.interfaces) { iface in
                        Text(iface.displayName).tag(Optional(iface))
                    }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: 320)
            }

            if let local = state.localURL {
                Text("备选地址：\(local)")
                    .font(.caption2).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        VStack(spacing: 10) {
            if let folder = state.folderURL {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(folder.path).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("更换") { state.pickFolder() }.controlSize(.small)
                    Button(state.isRunning ? "停止" : "启动") { state.toggle() }
                        .controlSize(.small)
                }
            }

            if let err = state.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            DisclosureGroup("手机打不开？") {
                VStack(alignment: .leading, spacing: 6) {
                    Label("确认手机和这台 Mac 连的是同一个 WiFi。", systemImage: "1.circle")
                    Label("首次启动若弹出防火墙提示，请点“允许”。", systemImage: "2.circle")
                    Label("部分公司/公共 WiFi 开了“设备隔离”，会阻止互访，换个网络试试。", systemImage: "3.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            }
            .font(.caption)
        }
    }

    // MARK: - 动作

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}
