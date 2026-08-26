import Foundation
import Darwin

// 一块网卡上的一个私网 IPv4 地址。
struct NetworkInterface: Identifiable, Hashable {
    let name: String // 接口名，如 en0
    let ip: String // 私网 IPv4，如 192.168.1.20
    var id: String { "\(name)|\(ip)" }

    // 在 GUI 信号源选择器展示，故按 app 语言；由调用方传入 lang。
    func displayName(_ lang: Lang) -> String {
        if name == "en0" { return "Wi‑Fi · \(ip)" }
        if name.hasPrefix("en") { return "\(lang == .zh ? "以太网" : "Ethernet") \(name) · \(ip)" }
        return "\(name) · \(ip)"
    }
}

// 枚举本机网络接口，挑出手机在同一 WiFi 下真正能连上的私网 IPv4。
// 关键：过滤掉 VPN(utun)、bridge、回环等手机连不上的地址——这是“扫码却打不开”的常见坑。
enum NetworkInfo {
    static func privateIPv4Interfaces() -> [NetworkInterface] {
        allIPv4Interfaces().filter { isPrivateIPv4($0.ip) }.sorted(by: rank)
    }

    // Tailscale 为节点分配 100.64.0.0/10 内的稳定 IPv4。它不进入普通局域网信号源列表，只有用户
    // 显式开启 Tailscale 访问后才用于额外地址；按 CIDR 而非 utun 名称识别，兼容不同安装形态。
    static func tailscaleIPv4Address() -> String? {
        allIPv4Interfaces().first { isTailscaleIPv4($0.ip) }?.ip
    }

    static func isTailscaleIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4,
              let first = Int(parts[0]), let second = Int(parts[1]),
              parts[2...].allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return false }
        return first == 100 && (64...127).contains(second)
    }

    // Bonjour 主机名只在确有 .local 名称时展示；不自行拼接后缀，避免生成一条无法解析的地址。
    static func localHostName() -> String? {
        let name = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.lowercased().hasSuffix(".local"), !name.contains(":") else { return nil }
        return name
    }

    private static func allIPv4Interfaces() -> [NetworkInterface] {
        var result: [NetworkInterface] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0 else { return [] }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor = ifaddrPtr
        while let ptr = cursor {
            defer { cursor = ptr.pointee.ifa_next }
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 else { continue }
            guard sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let r = getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard r == 0 else { continue }

            let ip = String(cString: host)
            let iface = NetworkInterface(name: String(cString: ifa.ifa_name), ip: ip)
            if !result.contains(iface) { result.append(iface) }
        }
        return result
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("192.168.") || ip.hasPrefix("10.") { return true }
        // 172.16.0.0 – 172.31.255.255
        let parts = ip.split(separator: ".")
        if parts.count == 4, parts[0] == "172", let second = Int(parts[1]), (16...31).contains(second) {
            return true
        }
        return false
    }

    // 排序：en0(WiFi) 最优先，其次其它 en*，最后其它接口。
    private static func rank(_ a: NetworkInterface, _ b: NetworkInterface) -> Bool {
        func score(_ n: String) -> Int {
            if n == "en0" { return 0 }
            if n.hasPrefix("en") { return 1 }
            return 2
        }
        let sa = score(a.name), sb = score(b.name)
        return sa != sb ? sa < sb : a.ip < b.ip
    }
}
