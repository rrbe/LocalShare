import SwiftUI

// 单窗口 UI（暖纸张 × 信号广播）：刊头 + 信号源(二维码/频率/链接) + 文件夹底座。
// 三态：未选文件夹 / 未接入局域网 / 广播中。视觉系统见 Theme.swift。
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var appeared = false

    var body: some View {
        ZStack {
            PaperBackground()
            VStack(spacing: 18) {
                masthead
                content
                Spacer(minLength: 0)
                footer
            }
            .frame(maxWidth: 430)                                   // 内容收成定宽列
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // 在窗口内水平居中
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 22)
        }
        .frame(minWidth: 460, idealWidth: 500, maxWidth: 540,
               minHeight: 680, idealHeight: 720, maxHeight: .infinity)
        .preferredColorScheme(.light)
        .onAppear { appeared = true }
    }

    // MARK: - 刊头

    private var masthead: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("局域网 · 只读分享")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.signal)
                Text("局域网文件分享")
                    .font(.serif(25)).foregroundStyle(Palette.ink)
            }
            Spacer()
            statusTag
        }
    }

    private var statusTag: some View {
        HStack(spacing: 7) {
            LiveDot(color: state.isRunning ? Palette.signal : Palette.inkSoft, live: state.isRunning)
            if state.isRunning {
                Text("广播中").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.ink)
                Text(":\(String(state.port))").font(.mono(11, .semibold)).foregroundStyle(Palette.signal)
            } else {
                Text("待机").font(.mono(10, .medium)).tracking(1).foregroundStyle(Palette.inkSoft)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().stroke(Palette.line, lineWidth: 1))
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

    // 未选文件夹
    private var emptyFolderState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("◐").font(.system(size: 64)).foregroundStyle(Palette.signal.opacity(0.85))
            Text("选择一个文件夹，开始广播")
                .font(.serif(21)).foregroundStyle(Palette.ink)
            Text("同一网络下的任意设备——手机、电脑、平板——\n扫码或打开链接即可在浏览器里只读浏览。")
                .font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center).lineSpacing(3)
            Button("选择文件夹…") { state.pickFolder() }
                .buttonStyle(SignalButtonStyle()).hoverLift().padding(.top, 4)
            Spacer()
        }
    }

    // 未接入局域网
    private var noNetworkState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("⌁").font(.system(size: 64)).foregroundStyle(Palette.inkSoft.opacity(0.7))
            Text("未接入局域网").font(.serif(21)).foregroundStyle(Palette.ink)
            Text("先把这台 Mac 接入与目标设备相同的 WiFi /\n有线网络，再点下方刷新。")
                .font(.system(size: 13)).foregroundStyle(Palette.inkSoft)
                .multilineTextAlignment(.center).lineSpacing(3)
            Button("刷新网络") { state.refreshNetwork() }
                .buttonStyle(GhostButtonStyle()).hoverLift().padding(.top, 4)
            Spacer()
        }
    }

    // 广播中
    private var runningState: some View {
        VStack(spacing: 16) {
            signalCard.enter(appeared, 0.05)
            if let iface = state.selectedInterface {
                frequency(iface).enter(appeared, 0.13)
            }
            if let url = state.primaryURL {
                linkBar(url).enter(appeared, 0.21)
            }
            if state.interfaces.count > 1 {
                interfacePicker.enter(appeared, 0.27)
            }
            if let local = state.localURL {
                Text("备用 · \(local)")
                    .font(.mono(10)).foregroundStyle(Palette.inkSoft.opacity(0.8))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .enter(appeared, 0.31)
            }
        }
    }

    // 信号源卡片：电波环 + 二维码 + 套准角标
    private var signalCard: some View {
        VStack(spacing: 16) {
            ZStack {
                BroadcastRings().frame(width: 250, height: 250)
                if let qr = state.qrImage {
                    Image(nsImage: qr)
                        .interpolation(.none).resizable()
                        .frame(width: 212, height: 212)
                        .padding(16)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Palette.line, lineWidth: 1))
                        .overlay(CropMarks(color: Palette.inkSoft.opacity(0.5)).padding(-9))
                        .shadow(color: Palette.ink.opacity(0.12), radius: 18, x: 0, y: 10)
                }
            }
            .frame(height: 250)
            Text("扫码 · 或在任意设备的浏览器中打开")
                .font(.mono(10)).tracking(0.3).foregroundStyle(Palette.inkSoft)
        }
    }

    // 频率读数：IP 大字 + 端口强调
    private func frequency(_ iface: NetworkInterface) -> some View {
        VStack(spacing: 2) {
            Text("调频至").font(.system(size: 10, weight: .medium)).tracking(0.5).foregroundStyle(Palette.inkSoft)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(iface.ip).font(.mono(26, .medium)).foregroundStyle(Palette.ink)
                Text(":\(String(state.port))").font(.mono(26, .semibold)).foregroundStyle(Palette.signal)
            }
            .textSelection(.enabled)
        }
    }

    // 链接条：完整 URL + 复制 / 打开
    private func linkBar(_ url: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(Palette.inkSoft)
            Text(url)
                .font(.mono(11.5)).foregroundStyle(Palette.inkSoft)
                .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(IconButtonStyle()).hoverLift().help("复制链接")
            Button { open(url) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(IconButtonStyle()).hoverLift().help("在本机浏览器打开（自测）")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Palette.surface.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Palette.line, lineWidth: 1))
    }

    // 信号源（网卡）选择
    private var interfacePicker: some View {
        Menu {
            ForEach(state.interfaces) { iface in
                Button(iface.displayName) { state.selectedInterface = iface }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11))
                Text(state.selectedInterface?.displayName ?? "选择信号源").font(.mono(11))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Capsule().stroke(Palette.line, lineWidth: 1))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    // MARK: - 底座

    private var footer: some View {
        VStack(spacing: 12) {
            if let folder = state.folderURL {
                HStack(spacing: 11) {
                    Image(systemName: "shippingbox").font(.system(size: 15)).foregroundStyle(Palette.signal)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("正在广播").font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(Palette.inkSoft)
                        Text(folder.lastPathComponent)
                            .font(.serif(15, .medium)).foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 6)
                    Button("更换") { state.pickFolder() }.buttonStyle(GhostButtonStyle()).hoverLift()
                    Button(state.isRunning ? "停止" : "启动") { state.toggle() }
                        .buttonStyle(GhostButtonStyle()).hoverLift()
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Palette.surface.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(Palette.line, lineWidth: 1))
            }

            if let err = state.lastError {
                Text(err).font(.system(size: 11.5)).foregroundStyle(Palette.signal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    troubleshootRow("1", "确认两台设备连的是同一个 WiFi / 网络。")
                    troubleshootRow("2", "首次启动若弹出防火墙提示，请点「允许」。")
                    troubleshootRow("3", "公司 / 公共 WiFi 常开「设备隔离」，会阻止互访，换个网络试试。")
                }
                .padding(.top, 8)
            } label: {
                Text("连不上？").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.inkSoft)
            }
            .tint(Palette.inkSoft)
        }
    }

    private func troubleshootRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n).font(.mono(10, .semibold)).foregroundStyle(Palette.signal)
                .frame(width: 16, height: 16)
                .background(Circle().stroke(Palette.signal.opacity(0.4), lineWidth: 1))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Palette.inkSoft).lineSpacing(2)
            Spacer(minLength: 0)
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
