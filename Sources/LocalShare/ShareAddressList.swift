import SwiftUI
import AppKit

// 同一列表内按访问范围分组；网络开关与二维码选择互相独立。
struct ShareAddressList: View {
    let t: Theme
    @State private var hostnameExpanded = false
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            VStack(spacing: 0) {
                if !localAddresses.isEmpty {
                    localSection
                    Divider().overlay(t.line)
                }
                RemoteAccessCard(t: t)
                if state.tailscaleStatus != nil {
                    Divider().overlay(t.line)
                    tailscaleSection
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line, lineWidth: 1))
        }
    }

    private var localAddresses: [ShareAddress] {
        state.shareAddresses.filter { $0.scope == .localNetwork }
    }

    private var localSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "wifi").font(.system(size: 12)).foregroundStyle(t.inkMute)
                Text(L.localNetwork(state.lang)).font(.sans(12, .semibold))
                Text(L.sameNetwork(state.lang)).font(.sans(10.5)).foregroundStyle(t.inkMute)
                Spacer(minLength: 0)
            }
            .foregroundStyle(t.ink)
            .padding(12)
            ForEach(localAddresses.filter { $0.kind == .localIP || hostnameExpanded }) { address in
                ShareAddressRow(t: t, address: address)
            }
            if localAddresses.contains(where: { $0.kind == .localHostname }) {
                hostnameDisclosure
            }
        }
        .padding(.bottom, 4)
    }

    private var hostnameDisclosure: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { hostnameExpanded.toggle() }
        } label: {
            Image(systemName: hostnameExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold)).foregroundStyle(t.inkMute)
                .frame(maxWidth: .infinity).frame(height: 16)
                .background(alignment: .top) {
                    if !hostnameExpanded,
                       let hostname = localAddresses.first(where: { $0.kind == .localHostname }) {
                        ShareAddressRow(t: t, address: hostname)
                            .frame(height: 16, alignment: .top).clipped()
                            .blur(radius: 4)
                            .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L.localHostname(state.lang))
        .accessibilityLabel(Text(L.localHostname(state.lang)))
        .accessibilityValue(Text(hostnameExpanded ? L.collapseAddress(state.lang) : L.expandAddress(state.lang)))
        .padding(.horizontal, 6).padding(.top, 1).padding(.bottom, 2)
    }

    private var tailscaleSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "network").font(.system(size: 12)).foregroundStyle(t.inkMute)
                Text("Tailscale").font(.sans(12, .semibold)).foregroundStyle(t.ink)
                Text(L.tailscaleAccessHint(state.lang)).font(.sans(10.5)).foregroundStyle(t.inkMute)
                    .lineLimit(1).truncationMode(.tail)
                    .help(L.tailscaleAccessHint(state.lang))
                Spacer(minLength: 0)
                ToggleSwitch(t: t, isOn: state.tailscaleAccessEnabled) {
                    state.setTailscaleAccessEnabled(!state.tailscaleAccessEnabled)
                }
                .accessibilityLabel(Text(L.tailscaleTitle(state.lang)))
                .accessibilityValue(Text(state.tailscaleAccessEnabled ? L.accessEnabled(state.lang) : L.accessDisabled(state.lang)))
            }
            .padding(12)
            ForEach(state.shareAddresses.filter { $0.scope == .tailscale }) { address in
                ShareAddressRow(t: t, address: address)
            }
        }
        .padding(.bottom, state.tailscaleAccessEnabled && state.isRunning ? 6 : 0)
    }

}

struct ShareAccessMode: View {
    let t: Theme
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                option(L.shareLink, usingCode: false)
                option(L.accessCodeMode, usingCode: true)
            }
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 10).fill(t.surfaceAlt))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(t.line, lineWidth: 1))
            Group {
                if let code = state.presentedAccessCode {
                    AccessCodePill(t: t, lang: state.lang, value: code)
                } else {
                    Text(L.shareLinkHint(state.lang)).font(.sans(14, .medium)).foregroundStyle(t.ink)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 40)
        }
    }

    private func option(_ title: L, usingCode: Bool) -> some View {
        let selected = state.accessCodeEnabled == usingCode
        return Button { state.setAccessCodeEnabled(usingCode) } label: {
            Text(title(state.lang)).font(.sans(12, .semibold))
                .foregroundStyle(selected ? .white : t.inkMute)
                .frame(maxWidth: .infinity).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(selected ? t.accent : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ShareAddressRow: View {
    let t: Theme
    let address: ShareAddress
    @EnvironmentObject var state: AppState
    @State private var copied = false
    @State private var expanded = false

    private var selected: Bool { state.selectedShareAddress?.kind == address.kind }
    private var relayHost: String? {
        address.kind == .publicRelay ? URL(string: address.url)?.host?.lowercased() : nil
    }

    var body: some View {
        Button { state.selectShareAddress(address.kind) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(title).font(.sans(10.5, .medium))
                        .foregroundStyle(selected ? t.accent : t.inkMute)
                        .fixedSize(horizontal: true, vertical: false)
                    if let host = relayHost {
                        Text("|").font(.sans(10.5)).foregroundStyle(t.inkMute)
                        Text(host).font(.sans(10.5)).foregroundStyle(t.inkMute)
                            .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                            .help(host)
                        if host == URL(string: RemoteSettings.defaultServerAddress)?.host {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 11))
                                .foregroundStyle(t.ok).fixedSize()
                                .help(L.remoteDefaultService(state.lang))
                                .accessibilityLabel(Text(L.remoteDefaultService(state.lang)))
                        }
                    }
                    if relayHost == nil { Spacer(minLength: 0) }
                }
                .frame(minHeight: 24).padding(.trailing, 84)
                Text(address.url).font(.mono(11.5)).foregroundStyle(t.ink)
                    .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? t.accentSoft : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(address.url)
        .accessibilityLabel(Text("\(title) · \(address.url)"))
        .accessibilityHint(Text(L.showAddressQR(state.lang)))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                HoverIcon(t: t,
                          systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          color: t.inkMute,
                          help: expanded ? L.collapseAddress(state.lang) : L.expandAddress(state.lang),
                          size: 24, iconSize: 12) { expanded.toggle() }
                HoverIcon(t: t, systemImage: copied ? "checkmark" : "doc.on.doc",
                          color: copied ? t.ok : t.inkMute, help: L.copy(state.lang),
                          size: 24, iconSize: 12) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(address.url, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
                }
                HoverIcon(t: t, systemImage: "arrow.up.right", color: t.inkMute,
                          help: L.openInBrowser(state.lang), size: 24, iconSize: 12) {
                    if let url = URL(string: address.url) { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.trailing, 9).padding(.top, 6)
        }
        .padding(.horizontal, 6).padding(.bottom, 3)
    }

    private var title: String {
        switch address.kind {
        case .localIP, .tailscaleIP: return L.localIPAddress(state.lang)
        case .localHostname: return L.localHostname(state.lang)
        case .tailscaleMagicDNS: return "MagicDNS"
        case .publicRelay: return L.usingRelayService(state.lang)
        }
    }
}

struct ShareQRScope: View {
    let t: Theme
    @EnvironmentObject var state: AppState

    var body: some View {
        if let address = state.selectedShareAddress {
            HStack(spacing: 8) {
                Text(scopeTitle(address.scope)).font(.sans(12, .semibold)).foregroundStyle(t.ink)
                Text(scopeHint(address.scope)).font(.sans(10.5)).foregroundStyle(t.inkMute)
            }
        }
    }

    private func scopeTitle(_ scope: ShareAddress.Scope) -> String {
        switch scope {
        case .localNetwork: return L.localNetwork(state.lang)
        case .tailscale: return "Tailscale"
        case .publicInternet: return L.internet(state.lang)
        }
    }

    private func scopeHint(_ scope: ShareAddress.Scope) -> String {
        switch scope {
        case .localNetwork: return L.sameNetwork(state.lang)
        case .tailscale: return L.tailscaleAccessHint(state.lang)
        case .publicInternet: return L.internetAccessHint(state.lang)
        }
    }
}
