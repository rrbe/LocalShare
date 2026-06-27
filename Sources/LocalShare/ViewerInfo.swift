import Foundation

// 一名在线访客的明细（仅在分享者本机窗口展示，绝不外泄给网页端）。
// name 是反查到的设备名，查不到为空串；ip 始终是完整 IPv4。
struct ViewerInfo: Identifiable {
    let ip: String
    let name: String        // 反查到的设备名，查不到为空串
    let since: Date         // 本次浏览会话首次出现时间（断开超出在线窗口再来即重新计）
    var id: String { ip }
    // 展开列表：设备名优先，查不到显示完整 IP（不再只剩尾号，便于区分是哪几台）。
    var fullLabel: String { name.isEmpty ? ip : name }
}
