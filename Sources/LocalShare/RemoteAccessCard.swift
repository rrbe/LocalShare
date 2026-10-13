import SwiftUI

// 统一地址列表中的互联网分组。
struct RemoteAccessCard: View {
    let t: Theme
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(t.inkMute)
                Text(L.internet(state.lang)).font(.sans(12, .semibold)).foregroundStyle(t.ink)
                    .fixedSize()
                Text(L.internetAccessHint(state.lang)).font(.sans(10.5)).foregroundStyle(t.inkMute)
                    .lineLimit(1).truncationMode(.tail)
                    .help(L.internetAccessHint(state.lang))
                Spacer(minLength: 0)
                if state.remoteAccessEnabled || state.remoteError != nil {
                    Circle().fill(remoteStatusColor).frame(width: 6, height: 6)
                        .help(remoteStatusText)
                        .accessibilityLabel(Text(remoteStatusText))
                }
                ToggleSwitch(t: t, isOn: state.remoteAccessEnabled,
                             locked: !state.remoteAccessEnabled && !state.canEnableRemote) {
                    if state.remoteAccessEnabled { state.disconnectRemote() }
                    else { state.connectRemote(enrollmentKey: state.remoteEnrollmentKey) }
                }
                .accessibilityLabel(Text(L.remoteAccess(state.lang)))
                .accessibilityValue(Text(state.remoteAccessEnabled ? L.accessEnabled(state.lang) : L.accessDisabled(state.lang)))
            }
            .padding(12)
            ForEach(state.shareAddresses.filter { $0.scope == .publicInternet }) { address in
                ShareAddressRow(t: t, address: address)
            }
            if let error = state.remoteError, !error.isEmpty {
                Text(error).font(.sans(11)).foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            } else if !state.remoteSettings.isValid {
                Text(L.remoteConfigHint(state.lang)).font(.sans(11)).foregroundStyle(t.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if state.screen == .text {
                HStack(spacing: 8) {
                    Text(L.remoteReceiveText(state.lang)).font(.sans(12)).foregroundStyle(t.ink)
                    Spacer(minLength: 0)
                    ToggleSwitch(t: t, isOn: state.remoteTextInboxEnabled) {
                        state.setRemoteTextInboxEnabled(!state.remoteTextInboxEnabled)
                    }
                    .accessibilityLabel(Text(L.remoteReceiveText(state.lang)))
                    .accessibilityValue(Text(state.remoteTextInboxEnabled ? L.accessEnabled(state.lang) : L.accessDisabled(state.lang)))
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            if state.remoteAccessEnabled {
                HStack(spacing: 8) {
                    Label(L.remotePrivacy(state.lang), systemImage: "exclamationmark.triangle")
                        .font(.sans(10.5)).foregroundStyle(t.warn)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    RemoteGuideLink(t: t, lang: state.lang)
                }
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
    }

    private var remoteStatusText: String {
        if let error = state.remoteError, !state.remoteAccessEnabled { return error }
        switch state.remoteStatus {
        case .connecting: return L.remoteConnecting(state.lang)
        case .connected: return L.remoteOnline(state.lang)
        case .reconnecting: return L.remoteOffline(state.lang)
        case .disconnected: return L.accessDisabled(state.lang)
        }
    }

    private var remoteStatusColor: Color {
        if state.remoteError != nil, !state.remoteAccessEnabled { return t.danger }
        switch state.remoteStatus {
        case .connected: return t.ok
        case .reconnecting: return t.danger
        case .connecting: return t.warn
        case .disconnected: return t.inkFaint
        }
    }
}

struct RemoteGuideLink: View {
    let t: Theme
    let lang: Lang

    var body: some View {
        Link(L.remoteGuide(lang), destination: URL(string: "https://github.com/rrbe/LocalShare/blob/master/website/server/connect-client.md")!)
            .font(.sans(11)).foregroundStyle(t.accent)
            .buttonStyle(.plain)
    }
}
