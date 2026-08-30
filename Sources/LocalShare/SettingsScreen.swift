import SwiftUI
import AppKit

// MARK: - 设置（左侧分类导航 / 右侧分类内容）

struct SettingsScreen: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var updater: UpdaterController
    @State private var portText = ""
    @State private var remoteServerText = ""
    @State private var remoteKeyText = ""
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
            }
        } content: {
            HStack(alignment: .top, spacing: 20) {
                settingsSidebar(lang)
                settingsDetail(lang: lang, portCheck: pv, portColor: pColor,
                               portChanged: changed, permissionSummary: ps,
                               tailscaleDescription: tailscaleDesc)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            portText = String(state.configuredPort)
            remoteServerText = state.remoteSettings.serverAddress
            remoteKeyText = state.remoteEnrollmentKey
            state.refreshCLIStatus()
        }
        .onDisappear { state.endSettingsLayout() }
    }

    // MARK: - 经典设置侧栏

    private func settingsSidebar(_ lang: Lang) -> some View {
        VStack(spacing: 4) {
            ForEach(AppState.SettingsCategory.allCases, id: \.self) { category in
                let selected = state.selectedSettingsCategory == category
                Button { state.selectedSettingsCategory = category } label: {
                    HStack(spacing: 10) {
                        Image(systemName: categoryIcon(category))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(selected ? t.accent : t.inkMute)
                            .frame(width: 18)
                        Text(categoryTitle(category, lang))
                            .font(.sans(13, selected ? .semibold : .medium))
                            .foregroundStyle(t.ink)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .contentShape(Rectangle())
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(selected ? t.accentSoft : .clear))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(7)
        .frame(width: 184)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    private func categoryTitle(_ category: AppState.SettingsCategory, _ lang: Lang) -> String {
        switch category {
        case .network: return L.sectionNetwork(lang)
        case .remote: return L.sectionRemote(lang)
        case .permission: return L.sectionPermission(lang)
        case .appearanceLanguage: return L.sectionAppearanceLanguage(lang)
        case .main: return L.sectionMain(lang)
        case .update: return L.sectionUpdate(lang)
        case .cli: return L.sectionCLI(lang)
        }
    }

    private func categoryIcon(_ category: AppState.SettingsCategory) -> String {
        switch category {
        case .network: return "network"
        case .remote: return "globe"
        case .permission: return "lock.shield"
        case .appearanceLanguage: return "paintbrush"
        case .main: return "macwindow"
        case .update: return "arrow.triangle.2.circlepath"
        case .cli: return "terminal"
        }
    }

    @ViewBuilder private func settingsDetail(lang: Lang, portCheck: PortCheck, portColor: Color,
                                              portChanged: Bool, permissionSummary: PermSummary,
                                              tailscaleDescription: String) -> some View {
        switch state.selectedSettingsCategory {
        case .network:
            networkSettings(lang: lang, portCheck: portCheck, portColor: portColor,
                            portChanged: portChanged, tailscaleDescription: tailscaleDescription)
        case .remote:
            remoteAccessSettings(lang)
        case .permission:
            permissionSettings(lang: lang, summary: permissionSummary)
        case .appearanceLanguage:
            appearanceLanguageSettings(lang)
        case .main:
            mainSettings(lang)
        case .update:
            updateSettings(lang)
        case .cli:
            cliSettings(lang)
        }
    }

    private func networkSettings(lang: Lang, portCheck: PortCheck, portColor: Color,
                                 portChanged: Bool, tailscaleDescription: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text("\(state.selectedInterface?.ip ?? L.thisMachine(lang)) :")
                            .font(.mono(14)).foregroundStyle(t.inkMute)
                        TextField("", text: $portText)
                            .textFieldStyle(.plain)
                            .font(.mono(15, .bold)).foregroundStyle(t.ink)
                            .frame(width: 72)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.field))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(portCheck.state == .ok ? t.lineStrong : portColor, lineWidth: 1.5))
                            .onChange(of: portText) { portText = String($0.filter(\.isNumber).prefix(5)) }
                            .onSubmit { apply(portCheck, changed: portChanged) }
                        Spacer()
                        HStack(spacing: 5) {
                            Image(systemName: portCheck.state == .ok ? "checkmark" : "questionmark.circle")
                                .font(.system(size: 13, weight: .bold))
                            Text(portCheck.state == .ok ? L.portOk(lang)
                                 : (portCheck.state == .occupied ? L.portOccupied(lang) : L.portInvalid(lang)))
                                .font(.sans(11.5, .bold))
                        }
                        .foregroundStyle(portColor)
                    }

                    HStack(alignment: .top, spacing: 8) {
                        Text(portCheck.state == .ok ? L.portOkHint(lang) : portCheck.message)
                            .font(.sans(11.5, portCheck.state == .ok ? .regular : .semibold))
                            .foregroundStyle(portCheck.state == .ok ? t.inkMute : portColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        if let suggestion = portCheck.suggest {
                            Button { portText = String(suggestion) } label: {
                                Text(LStr.changeToPort(suggestion, lang)).font(.sans(11.5, .bold)).foregroundStyle(t.accent)
                                    .padding(.horizontal, 10).frame(height: 24)
                                    .background(Capsule().fill(t.accentSoft))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)

                    if portChanged {
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
                            if portCheck.state != .invalid {
                                Button { apply(portCheck, changed: portChanged) } label: {
                                    Text(L.applyRestart(lang)).font(.sans(13, .semibold)).foregroundStyle(t.accent)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 12)
                    }
                }
                .padding(.vertical, 12)

                settingRow(top: true, title: L.tailscaleTitle(lang), desc: tailscaleDescription) {
                    ToggleSwitch(t: t, isOn: state.tailscaleAccessEnabled) {
                        state.setTailscaleAccessEnabled(!state.tailscaleAccessEnabled)
                    }
                }
            }
        }
    }

    private func remoteAccessSettings(_ lang: Lang) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupBox {
                remoteField(title: L.remoteServerAddress(lang), text: $remoteServerText)
                if !state.remotePaired {
                    remoteField(title: L.remoteEnrollmentKey(lang), text: $remoteKeyText, top: true)
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "key.horizontal").font(.system(size: 13)).foregroundStyle(t.accent)
                    Text(L.remotePairHint(lang)).font(.sans(11.5)).foregroundStyle(t.inkMute)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                HStack {
                    Spacer()
                    GhostButton(t: t, title: L.remoteSave(lang), systemImage: "checkmark") {
                        saveRemoteSettings()
                    }
                    if state.remotePaired {
                        Button { state.forgetRemoteDevice() } label: {
                            Text(L.remoteForget(lang)).font(.sans(12.5, .semibold)).foregroundStyle(t.danger)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func permissionSettings(lang: Lang, summary: PermSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupBox {
                permRow(name: L.permReadName(lang), desc: L.permReadDesc(lang), locked: true, on: true)
                permRow(name: L.accessCodeTitle(lang), desc: L.accessCodeDesc(lang),
                        locked: false, on: state.accessCodeEnabled, top: true) {
                    state.setAccessCodeEnabled(!state.accessCodeEnabled)
                }
                permRow(name: L.permUploadName(lang),
                        desc: state.remoteAccessEnabled ? L.remoteReadOnly(lang)
                                                       : (state.canToggleUpload ? L.permUploadDescOn(lang) : L.permUploadDescOff(lang)),
                        locked: !state.canToggleUpload || state.remoteAccessEnabled,
                        on: state.permission.add, top: true) {
                    state.setUploadAllowed(!state.permission.add)
                }
                permRow(name: L.recvInboxTitle(lang),
                        desc: state.remoteAccessEnabled ? L.remoteReadOnly(lang) : L.recvInboxDesc(lang),
                        locked: state.remoteAccessEnabled, on: state.textInboxEnabled, top: true) {
                    state.setTextInboxEnabled(!state.textInboxEnabled)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle").font(.system(size: 14)).foregroundStyle(t.accent).padding(.top, 1)
                Text(summary.writable ? L.permInfoWritable(lang) : L.permInfoReadonly(lang))
                    .font(.sans(11.5)).foregroundStyle(t.dark ? t.ink : Color(hex: 0x8a3a1e)).lineSpacing(2)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.accentSoft))
            .padding(.top, 12)

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.open").font(.system(size: 13)).foregroundStyle(t.inkMute).padding(.top, 1)
                Text(L.plaintextWarning(lang)).font(.sans(11.5)).foregroundStyle(t.inkMute).lineSpacing(2)
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
    }

    private func appearanceLanguageSettings(_ lang: Lang) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            eyebrow(L.sectionAppearance(lang), first: true)
            HStack(spacing: 8) {
                appearanceSeg(L.appearanceFollow(lang), .system)
                appearanceSeg(L.appearanceLight(lang), .light)
                appearanceSeg(L.appearanceDark(lang), .dark)
            }
            eyebrow(L.sectionLanguage(lang))
            HStack(spacing: 8) {
                langSeg(L.langFollow(lang), .system)
                langSeg("中文", .zh)
                langSeg("English", .en)
            }
        }
    }

    private func mainSettings(_ lang: Lang) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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
        }
    }

    private func updateSettings(_ lang: Lang) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            groupBox {
                settingRow(title: L.autoUpdate(lang),
                           desc: updater.isActive ? L.autoUpdateDescOn(lang) : L.autoUpdateDescOff(lang)) {
                    ToggleSwitch(t: t, isOn: updater.automaticChecks, locked: !updater.isActive) {
                        updater.setAutomaticChecks(!updater.automaticChecks)
                    }
                }
                settingRow(top: true, title: L.manualUpdate(lang),
                           desc: updater.isActive ? L.manualUpdateDescOn(lang) : L.manualUpdateDescOff(lang)) {
                    GhostButton(t: t, title: L.checkForUpdates(lang), systemImage: "arrow.clockwise") {
                        updater.checkForUpdates()
                    }
                    .disabled(!updater.canCheckForUpdates)
                    .opacity(updater.canCheckForUpdates ? 1 : 0.5)
                }
            }
        }
    }

    private func cliSettings(_ lang: Lang) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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

    // 分组卡：surface 底 + line 描边的圆角容器，把当前分类中的相关设置行包成一张卡。
    // 右侧仅在一个分类内仍有多个小节时使用 SectionLabel，左侧导航负责标出七个顶层分类。
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

    private func remoteField(title: String, text: Binding<String>, top: Bool = false,
                             width: CGFloat = 190, numbersOnly: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
            Spacer(minLength: 8)
            TextField("", text: text)
                .textFieldStyle(.plain)
                .font(.mono(11.5))
                .frame(width: width)
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(t.field))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(t.line, lineWidth: 1))
                .onChange(of: text.wrappedValue) { value in
                    if numbersOnly { text.wrappedValue = String(value.filter(\.isNumber).prefix(5)) }
                }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { if top { Rectangle().fill(t.line).frame(height: 1) } }
    }

    private func saveRemoteSettings() {
        state.saveRemoteSettings(RemoteSettings(serverAddress: remoteServerText), enrollmentKey: remoteKeyText)
        remoteKeyText = ""
    }
}
