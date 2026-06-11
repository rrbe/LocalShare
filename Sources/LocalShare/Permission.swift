import Foundation

// 权限模型（DESIGN.md §6.2）。read 锁定常开；add（访客上传）0.6 起接上真后端，仅单文件夹分享可开、
// 换分享自动回只读；edit/del 后端未实现、暂恒为 false（规划见 PLAN.md §7）。措辞框架统一：所有展示
// 分享态的界面（含网页 listing 页）都经 PermSummary 派生「只读 / 可读写」文案，绝不各自硬编码。
struct Permission: Equatable {
    var read = true   // 锁定常开
    var add = false   // 访客上传（0.6 起可用，FileServer.uploadEnabled 联动）
    var edit = false  // 访客在线编辑（未开放）
    var del = false   // 访客删除（未开放）
}

// 由单个 perm 对象派生每屏的只读/可读写文案，统一真相源。
struct PermSummary {
    let writable: Bool
    let writes: [String]   // 已开启的写权限中文名
    let tag: String        // 「只读」/「可读写」
    let eyebrow: String    // 「局域网 · 只读分享」/「局域网 · 可读写分享」
    let chips: [String]    // 只读 = [只读, 可下载]；可写 = [可下载, 可上传?, 可编辑?, 可删除?]
}

func permSummary(_ p: Permission) -> PermSummary {
    var writes: [String] = []
    if p.add { writes.append("上传") }
    if p.edit { writes.append("编辑") }
    if p.del { writes.append("删除") }
    let writable = !writes.isEmpty
    return PermSummary(
        writable: writable,
        writes: writes,
        tag: writable ? "可读写" : "只读",
        eyebrow: writable ? "局域网 · 可读写分享" : "局域网 · 只读分享",
        chips: writable ? ["可下载"] + writes.map { "可" + $0 } : ["只读", "可下载"]
    )
}
