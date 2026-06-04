import Foundation

// 会话访问令牌：每次 app 启动生成一次，内嵌进二维码 URL（?t=…）。
// 扫码者首访校验通过后种 cookie；手动猜 IP:端口 的人因缺 token 被 403。
enum Token {
    static func generate(length: Int = 10) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }
}
