import Foundation

// 供电脑间手动输入的短访问码。它不是分享 token：二维码与完整链接仍使用高熵 token，短码只在
// /ls/join 换取同一枚会话 Cookie。去掉易混淆的 0/O/1/I，6 位 base32 约 30 bits；服务端另有限流。
enum AccessCode {
    private static let alphabet = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")

    static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        let raw = String((0..<6).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
        return format(raw)
    }

    // 输入时容忍大小写、空格与连字符；其它字符保留后会自然校验失败，避免悄悄吞掉任意输入。
    static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0 != "-" && !$0.isWhitespace }
    }

    static func format(_ value: String) -> String {
        let normalized = normalize(value)
        guard normalized.count > 3 else { return normalized }
        let split = normalized.index(normalized.startIndex, offsetBy: 3)
        return String(normalized[..<split]) + "-" + String(normalized[split...])
    }
}
