import Foundation

// 展示地址与扫码地址分开：访问码模式展示 origin，扫码仍携带完整凭证。
struct ShareAddress: Identifiable, Equatable {
    enum Kind: String {
        case localIP
        case localHostname
        case tailscaleMagicDNS
        case tailscaleIP
        case publicRelay
    }

    enum Scope {
        case localNetwork
        case tailscale
        case publicInternet
    }

    let kind: Kind
    let scope: Scope
    let url: String
    let qrURL: String
    var id: Kind { kind }

    init(kind: Kind, scope: Scope, url: String, qrURL: String? = nil) {
        self.kind = kind
        self.scope = scope
        self.url = url
        self.qrURL = qrURL ?? url
    }
}
