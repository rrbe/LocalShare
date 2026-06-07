import Foundation

// 权限模型（DESIGN.md §6.2）。当前 v1 仅只读分享 —— 写权限（上传/编辑/删除）后端在 PLAN.md §6 标为
// 范围外、Swifter 也是只读的，故 add/edit/del 暂恒为 false。但措辞框架保留：所有展示分享态的界面都
// 经 PermSummary 派生「只读 / 可读写」文案，绝不各自硬编码 —— 将来接上写入后端时只需放开开关即可全局联动。
struct Permission: Equatable {
    var read = true   // 锁定常开
    var add = false   // 访客上传
    var edit = false  // 访客在线编辑
    var del = false   // 访客删除
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
