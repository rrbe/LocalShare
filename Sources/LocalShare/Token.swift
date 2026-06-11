import Foundation

// 分享访问令牌：每次「分享」动作生成一把（换分享/停止即轮换，旧链接与 cookie 随之作废），
// 内嵌进二维码 URL（?t=…）。扫码者首访校验通过后种 cookie；手动猜 IP:端口 的人因缺 token 被 403。
enum Token {
    static func generate(length: Int = 10) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }
}
