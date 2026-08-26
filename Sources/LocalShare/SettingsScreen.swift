import SwiftUI
import AppKit

// MARK: - 设置（网络 / 访问权限 / 外观 / 主界面 / 命令行工具）

struct SettingsScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterController
    @State private var portText = ""
    var body: some View {
        // portText 初始为空、onAppear 才填入当前端口；首帧若按空串校验会闪出「无效 + 放弃/应用」行再弹回。
        // 空串一律视作「当前生效端口」，让首帧与落定后一致，消除进入设置页时的这层闪烁。
        let lang = state.lang
        let effectivePort = portText.isEmpty ? String(state.configuredPort) : portText
        let pv = validatePort(effectivePort, lang)
        let pColor = pv.state == .ok ? t.ok : (pv.state == .occupied ? t.warn : t.danger)
        let changed = !portText.isEmpty && (Int(portText) ?? -1) != Int(state.configuredPort)
        let ps = permSummary(state.permission, lang)
        let tailscaleDesc = !state.tailscaleAccessEnabled ? L.tailscaleDescOff(lang)
            : (state.tailscaleStatus == nil ? L.tailscaleDescMissing(lang) : L.tailscaleDescOn(lang))
        return ScreenFrame(t: t) {
            HStack(spacing: 10) {
                IconButton(t: t, systemImage: "chevron.left", help: L.back(lang)) { state.goShare() }
                Text(L.shareSettings(lang)).font(.display(21, .semibold)).foregroundStyle(t.ink)
                Spacer()
                WideLayoutButton(t: t)
            }
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                // MARK: 网络（监听端口 + 可见范围）
                eyebrow(L.sectionNetwork(lang), first: true)
                groupBox {
                    // 端口编辑单元：IP 前缀 + 端口框 + 实时校验 +（改动时）放弃/应用，整体作卡内首格。
                    // 不再单独套一层 surface 卡（外层 groupBox 已提供卡面）；校验态由输入框边框 + 下方提示色承载。
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 10) {
                            Text("\(state.selectedInterface?.ip ?? L.thisMachine(lang)) :").font(.mono(14)).foregroundStyle(t.inkMute)
                            TextField("", text: $portText)
                                .textFieldStyle(.plain)
                                .font(.mono(15, .bold)).foregroundStyle(t.ink)
                                .frame(width: 72)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.field))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(pv.state == .ok ? t.lineStrong : pColor, lineWidth: 1.5))
                                .onChange(of: portText) { portText = String($0.filter(\.isNumber).prefix(5)) }
                                .onSubmit { apply(pv, changed: changed) }
                            Spacer()
                            HStack(spacing: 5) {
                                Image(systemName: pv.state == .ok ? "checkmark" : "questionmark.circle")
                                    .font(.system(size: 13, weight: .bold))
                                Text(pv.state == .ok ? L.portOk(lang) : (pv.state == .occupied ? L.portOccupied(lang) : L.portInvalid(lang)))
                                    .font(.sans(11.5, .bold))
                            }
                            .foregroundStyle(pColor)
                        }

                        HStack(alignment: .top, spacing: 8) {
                            Text(pv.state == .ok ? L.portOkHint(lang) : pv.message)
                                .font(.sans(11.5, pv.state == .ok ? .regular : .semibold))
                                .foregroundStyle(pv.state == .ok ? t.inkMute : pColor)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            if let s = pv.suggest {
                                Button { portText = String(s) } label: {
                                    Text(LStr.changeToPort(s, lang)).font(.sans(11.5, .bold)).foregroundStyle(t.accent)
                                        .padding(.horizontal, 10).frame(height: 24)
                                        .background(Capsule().fill(t.accentSoft))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 8)

                        // 改了才出现这排操作：放弃（还原成当前生效端口，无效输入也可退回）+ 应用。
                        // 用纯色文字而非实心全宽块——重启服务不是破坏性动作，不必视觉吓人。
                        if changed {
                            HStack(spacing: 18) {
                                Spacer()
                                Button { portText = String(state.configuredPort) } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12, weight: .semibold))
                                        Text(L.discardChanges(lang)).font(.sans(13, .semibold))
                                    }
                                    .foregroundStyle(t.inkMute)
                                }
                                .buttonStyle(.plain)
                                if pv.state != .invalid {
                                    Button { apply(pv, changed: changed) } label: {
                                        Text(L.applyRestart(lang)).font(.sans(13, .semibold)).foregroundStyle(t.accent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 12)
                        }
                    }
                    .padding(.vertical, 12)

                    settingRow(top: true, title: L.tailscaleTitle(lang), desc: tailscaleDesc) {
                        ToggleSwitch(t: t, isOn: state.tailscaleAccessEnabled) {
                            state.setTailscaleAccessEnabled(!state.tailscaleAccessEnabled)
                        }
                    }
                }

                // MARK: 访问权限（眼标右侧挂「当前权限」胶囊）
                HStack(spacing: 8) {
                    SectionLabel(t: t, text: L.sectionPermission(lang))
                    Spacer(minLength: 8)
                    Text("\(L.currentColon(lang))\(ps.tag)").font(.sans(11, .bold))
                        .foregroundStyle(ps.writable ? t.accent : t.inkMute)
                        .padding(.horizontal, 9).padding(.vertical, 2)
                        .background(Capsule().fill(ps.writable ? t.accentSoft : .clear))
                        .overlay(Capsule().strokeBorder(ps.writable ? .clear : t.line, lineWidth: 1))
                }
                .padding(.top, 22).padding(.bottom, 7).padding(.horizontal, 2)

                groupBox {
                    permRow(name: L.permReadName(lang), desc: L.permReadDesc(lang), locked: true, on: true)
                    permRow(name: L.accessCodeTitle(lang), desc: L.accessCodeDesc(lang),
                            locked: false, on: state.accessCodeEnabled, top: true) {
                        state.setAccessCodeEnabled(!state.accessCodeEnabled)
                    }
                    permRow(name: L.permUploadName(lang),
                            desc: state.canToggleUpload ? L.permUploadDescOn(lang) : L.permUploadDescOff(lang),
                            locked: !state.canToggleUpload,
                            on: state.permission.add, top: true) {
                        state.setUploadAllowed(!state.permission.add)
                    }
                    // 收文本：独立闸门，不限分享形态（甚至什么都没分享也能开），故不随 share 置灰。
                    permRow(name: L.recvInboxTitle(lang), desc: L.recvInboxDesc(lang),
                            locked: false, on: state.textInboxEnabled, top: true) {
                        state.setTextInboxEnabled(!state.textInboxEnabled)
                    }
                }

                // 权限级别说明 + 明文传输提示：作小节脚注列在卡片下方（非卡内行），与 macOS 分组表的页脚同姿态。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(t.accent).padding(.top, 1)
                    Text(ps.writable ? L.permInfoWritable(lang) : L.permInfoReadonly(lang))
                        .font(.sans(11.5)).foregroundStyle(t.dark ? t.ink : Color(hex: 0x8a3a1e)).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accentSoft))
                .padding(.top, 12)

                // 明文传输提示：纯 LAN 不加密，公共网络下同网的人能看到内容。用克制的灰字、不进彩底警告框。
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.open").font(.system(size: 13)).foregroundStyle(t.inkMute).padding(.top, 1)
                    Text(L.plaintextWarning(lang))
                        .font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)

                // MARK: 外观
                // 分段选择器本身即成组控件，自带分组感——不再套 groupBox（盒中盒），眼标下直接放分段条。
                eyebrow(L.sectionAppearance(lang))
                HStack(spacing: 8) {
                    appearanceSeg(L.appearanceFollow(lang), .system)
                    appearanceSeg(L.appearanceLight(lang), .light)
                    appearanceSeg(L.appearanceDark(lang), .dark)
                }

                // MARK: 语言
                eyebrow(L.sectionLanguage(lang))
                HStack(spacing: 8) {
                    langSeg(L.langFollow(lang), .system)
                    langSeg("中文", .zh)        // 语言名用本族文字，不翻译
                    langSeg("English", .en)
                }

                // MARK: 主界面（最近分享展示 + 窗口尺寸）
                eyebrow(L.sectionMain(lang))
                groupBox {
                    settingRow(title: L.showRecentsTitle(lang), desc: L.showRecentsDesc(lang)) {
                        ToggleSwitch(t: t, isOn: state.showRecents) { state.setShowRecents(!state.showRecents) }
                    }
                    settingRow(top: true, title: L.rememberTextTitle(lang), desc: L.rememberTextDesc(lang)) {
                        ToggleSwitch(t: t, isOn: state.persistText) { state.setPersistText(!state.persistText) }
                    }
                    settingRow(top: true, title: L.persistRecvTitle(lang), desc: L.persistRecvDesc(lang)) {
                        ToggleSwitch(t: t, isOn: state.persistReceivedText) { state.setPersistReceivedText(!state.persistReceivedText) }
                    }
                    settingRow(top: true, title: L.resetWindowTitle(lang), desc: L.resetWindowDesc(lang)) {
                        GhostButton(t: t, title: L.resetDefault(lang), systemImage: "arrow.counterclockwise") {
                            state.resetWindowSize()
                        }
                    }
                }

                // MARK: 更新
                // 始终展示这一组：开关留在设置里，用户才能确认「自动更新」这个功能确实存在。
                // dev / 未签名构建里 updater 未启动（占位 EdDSA 公钥），此时只把开关置灰、并改说明文案
                // 点明原因——是「此构建未启用」而非把整段藏掉。isActive 只决定可用态，不决定是否渲染。
                eyebrow(L.sectionUpdate(lang))
                groupBox {
                    settingRow(title: L.autoUpdate(lang),
                               desc: updater.isActive
                                    ? L.autoUpdateDescOn(lang)
                                    : L.autoUpdateDescOff(lang)) {
                        ToggleSwitch(t: t, isOn: updater.automaticChecks, locked: !updater.isActive) {
                            updater.setAutomaticChecks(!updater.automaticChecks)
                        }
                    }
                    settingRow(top: true,
                               title: L.manualUpdate(lang),
                               desc: updater.isActive
                                    ? L.manualUpdateDescOn(lang)
                                    : L.manualUpdateDescOff(lang)) {
                        GhostButton(t: t, title: L.checkForUpdates(lang), systemImage: "arrow.clockwise") {
                            updater.checkForUpdates()
                        }
                        .disabled(!updater.canCheckForUpdates)
                        .opacity(updater.canCheckForUpdates ? 1 : 0.5)
                    }
                }

                // MARK: 命令行工具
                // 裸二进制（swift run）没有 .app 可指：不给安装按钮，状态/卸载照常。
                eyebrow(L.sectionCLI(lang))
                groupBox {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("localshare").font(.mono(13.5, .bold)).foregroundStyle(t.ink)
                            Text(cliHint).font(.sans(11.5)).foregroundStyle(t.inkMute)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        if state.cliStatus != .notInstalled {
                            Button { state.uninstallCLI() } label: {
                                Text(L.uninstall(lang)).font(.sans(13, .semibold)).foregroundStyle(t.inkMute)
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 4)
                        }
                        if state.cliStatus == .installed {
                            HStack(spacing: 5) {
                                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                                Text(L.installed(lang)).font(.sans(11.5, .bold))
                            }
                            .foregroundStyle(t.ok)
                        } else if CLIInstaller.binaryPath() != nil {
                            GhostButton(t: t,
                                        title: state.cliStatus == .notInstalled ? L.install(lang) : L.reinstall(lang),
                                        systemImage: "terminal") {
                                state.installCLI()
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
            }
        }
        .onAppear {
            portText = String(state.configuredPort)
            state.refreshCLIStatus()
        }
    }

    // 命令行工具状态行：已安装显示链接路径；链接归属不了当前进程（裸跑/指向别处）时
    // 直接亮出实际指向，让人自己判断；未装时一句话点明用途或受限原因。
    private var cliHint: String {
        switch state.cliStatus {
        case .installed:
            return CLIInstaller.linkPath
        case .stale(let dest):
            return "→ " + (dest as NSString).abbreviatingWithTildeInPath
        case .notInstalled:
            return CLIInstaller.binaryPath() != nil ? L.cliHintAvailable(state.lang) : L.cliHintUnavailable(state.lang)
        }
    }

    // 分组卡：surface 底 + line 描边的圆角容器，把同一小节的行包成一张卡。分组切分由卡片边界承担，
    // 眼标（SectionLabel）只负责命名——这样安静的小标签不必再独力分隔七个组，「组标题比组内项小」的倒挂观感随之消除。
    // 组内多行靠 settingRow / permRow 自带的内缩顶分隔线区隔（行宽 = 卡内宽，分隔线天然内缩，不触卡缘）。
    @ViewBuilder private func groupBox<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    // 小节眼标 + 统一上下留白：组间距 22、标签到卡片 7；首组贴页顶不留上间距。
    private func eyebrow(_ text: String, first: Bool = false) -> some View {
        SectionLabel(t: t, text: text)
            .padding(.top, first ? 0 : 22).padding(.bottom, 7).padding(.horizontal, 2)
    }

    private func appearanceSeg(_ label: String, _ pref: AppState.AppearancePref) -> some View {
        let on = state.appearance == pref
        return Button { state.setAppearance(pref) } label: {
            Text(label).font(.sans(13, on ? .semibold : .medium))
                .foregroundStyle(on ? .white : t.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? t.accent : t.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? .clear : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 语言分段：结构同 appearanceSeg，绑 langPref / setLangPref。
    private func langSeg(_ label: String, _ pref: LangPref) -> some View {
        let on = state.langPref == pref
        return Button { state.setLangPref(pref) } label: {
            Text(label).font(.sans(13, on ? .semibold : .medium))
                .foregroundStyle(on ? .white : t.ink)
                .frame(maxWidth: .infinity).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? t.accent : t.surface))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? .clear : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // 通用设置行：「标题 +（可选）说明 + 右侧控件」。卡内多行靠 top 顶部分隔线区隔，
    // 每组首行不画线（top 默认 false）——分隔线只用来区隔相邻行，不与卡片上缘重复。
    private func settingRow<Trailing: View>(top: Bool = false, title: String, desc: String? = nil,
                                            @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                if let desc {
                    Text(desc).font(.sans(11.5)).foregroundStyle(t.inkMute)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }

    // 权限专用行（带「始终开启」标记与可锁定开关）。locked 且无 action = 锁定常开（读取）；
    // locked 且有 action = 当前形态不可用（开关置灰）。top 同 settingRow：仅相邻行间画分隔线。
    private func permRow(name: String, desc: String, locked: Bool, on: Bool, top: Bool = false,
                         action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                    if locked && action == nil { Text(L.alwaysOn(state.lang)).font(.sans(11)).foregroundStyle(t.inkFaint) }
                }
                Text(desc).font(.sans(11.5)).foregroundStyle(t.inkMute)
            }
            Spacer()
            ToggleSwitch(t: t, isOn: on, locked: locked, action: action ?? {})
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }

    private func apply(_ pv: PortCheck, changed: Bool) {
        guard pv.state != .invalid, changed, let p = Int(portText) else { return }
        state.applyPort(in_port_t(p))
        state.goShare()
    }
}
