import Foundation

// 手机投递到 Mac 的一段文本（传递文本 v2·收件箱条目）。由 FileServer 在 POST /ls/text 命中时构造，
// 经 onReceiveText 回调交给 AppState 持有（FileServer 不存收件箱列表）。Codable 供「持久化收到的文本」
// 落盘；Identifiable 供 SwiftUI 列表稳定标识。来源用反查到的设备名，查不到回退完整 IP（同 ViewerInfo）。
struct ReceivedText: Identifiable, Codable, Equatable {
    var id = UUID()
    let text: String
    let ip: String          // 来源 IPv4
    let name: String        // 反查到的设备名，查不到为空串
    let date: Date          // 收到时间
    // 收件箱里的来源标签：有设备名显名，否则显完整 IP。
    var source: String { name.isEmpty ? ip : name }
}
