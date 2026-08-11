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
            guard isPrivateIPv4(ip) else { continue }
            let iface = NetworkInterface(name: String(cString: ifa.ifa_name), ip: ip)
            if !result.contains(iface) { result.append(iface) }
        }
        return result.sorted(by: rank)
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
