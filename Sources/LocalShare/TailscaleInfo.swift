import Foundation

struct TailscaleStatus: Equatable, Sendable {
    let ipv4: String
    let dnsName: String?
}

// Tailscale 是可选能力：优先从系统网卡拿 100.64/10 地址；若本机安装了 CLI，再用一个有超时的
// `status --json --peers=false` 补出稳定的 MagicDNS 全名。找不到 CLI 或命令失败都安静退化为仅 IP。
enum TailscaleInfo {
    private static let executablePaths = [
        "/usr/local/bin/tailscale",
        "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    ]

    static func currentStatus(fallbackIPv4: String? = nil) -> TailscaleStatus? {
        guard let executable = executablePaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
              let data = runStatus(executable: executable),
              let status = parseStatus(data) else {
            return fallbackIPv4.map { TailscaleStatus(ipv4: $0, dnsName: nil) }
        }
        return status
    }

    static func parseStatus(_ data: Data) -> TailscaleStatus? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let selfNode = root["Self"] as? [String: Any] else { return nil }
        let ipv4 = (selfNode["TailscaleIPs"] as? [String])?
            .first(where: NetworkInfo.isTailscaleIPv4)
        guard let ipv4 else { return nil }
        let rawDNS = (selfNode["DNSName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let dnsName = rawDNS.flatMap { $0.isEmpty || $0.contains(":") ? nil : $0 }
        return TailscaleStatus(ipv4: ipv4, dnsName: dnsName)
    }

    private static func runStatus(executable: String) -> Data? {
        let process = Process()
        let pipe = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["status", "--json", "--peers=false"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        guard finished.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
