import Foundation

// 票据里的替代入口保存“完整可打开 URL”，而不是假定都能由 host + 本地 token 拼出。前三种当前
// 由本机生成；publicRelay 留给未来由中继服务返回不透明公网 URL，当前不会创建或展示。
struct ShareAddress: Identifiable, Equatable {
    enum Kind: String {
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
    var id: Kind { kind }
}
