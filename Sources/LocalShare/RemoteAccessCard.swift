import SwiftUI

struct RemoteAccessCard: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                GlobeLineIcon(color: t.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L.remoteAccess(state.lang)).font(.sans(13.5, .semibold)).foregroundStyle(t.ink)
                    if !state.remoteAccessEnabled {
                        Text(L.remoteAccessDesc(state.lang)).font(.sans(11.5)).foregroundStyle(t.inkMute)
                    }
                }
                Spacer(minLength: 8)
                if state.remoteAccessEnabled {
                    GhostButton(t: t, title: L.remoteDisconnect(state.lang), systemImage: "xmark.circle") {
                        state.disconnectRemote()
                    }
                } else {
                    GhostButton(t: t, title: L.remoteConnect(state.lang), systemImage: "link") {
                        state.connectRemote(enrollmentKey: state.remoteEnrollmentKey)
                    }
                    .disabled(!state.canEnableRemote)
                }
            }
            if state.remoteAccessEnabled {
                HStack(spacing: 7) {
                    Text(state.remoteSettings.displayAddress)
                        .font(.mono(11.5))
                        .foregroundStyle(t.inkMute)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Circle().fill(remoteStatusColor).frame(width: 7, height: 7)
                    Text(remoteStatusText).font(.sans(11.5, .semibold)).foregroundStyle(t.inkMute)
                }
                if let error = state.remoteError, !error.isEmpty {
                    Text(error).font(.sans(11)).foregroundStyle(t.danger).lineLimit(2)
                }
            } else if let error = state.remoteError, !error.isEmpty {
                Text(error)
                    .font(.sans(11.5)).foregroundStyle(t.danger)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !state.remoteSettings.isValid {
                Text(L.remoteConfigHint(state.lang))
                    .font(.sans(11.5)).foregroundStyle(t.inkMute)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if state.screen == .text {
                HStack {
                    Text(L.remoteReceiveText(state.lang)).font(.sans(12.5)).foregroundStyle(t.ink)
                    Spacer()
                    ToggleSwitch(t: t, isOn: state.remoteTextInboxEnabled) {
                        state.setRemoteTextInboxEnabled(!state.remoteTextInboxEnabled)
                    }
                }
            }
            HStack {
                Text(L.remotePrivacy(state.lang)).font(.sans(11)).foregroundStyle(t.inkMute)
                Spacer(minLength: 8)
                RemoteGuideLink(t: t, lang: state.lang)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(t.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    private var remoteStatusText: String {
        switch state.remoteStatus {
        case .connecting: return L.remoteConnecting(state.lang)
        case .connected: return L.remoteOnline(state.lang)
        case .reconnecting: return L.remoteOffline(state.lang)
        case .disconnected: return L.remoteConfigHint(state.lang)
        }
    }

    private var remoteStatusColor: Color {
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
