import Foundation
import Darwin

// MARK: - 端口实时校验（DESIGN.md §6.3）

enum PortState { case ok, occupied, invalid }

struct PortCheck {
    let state: PortState
    let message: String
    let suggest: in_port_t?
}

// 输入即校验：空 / 越界 → invalid；命中常用占用端口 → occupied + 建议下一个可用；其余 → ok。
// 占用集合为启发式（与设计稿一致）；真正能否绑定以「应用」时实际 start 结果为准。
func validatePort(_ raw: String, _ lang: Lang) -> PortCheck {
    let occupied: Set<Int> = [80, 443, 3000, 5000, 5432, 3306, 8000, 7890]
    let v = raw.trimmingCharacters(in: .whitespaces)
    guard !v.isEmpty else { return PortCheck(state: .invalid, message: L.portEmptyMsg(lang), suggest: nil) }
    guard let n = Int(v) else { return PortCheck(state: .invalid, message: L.portNotNumberMsg(lang), suggest: nil) }
    if n < 1024  { return PortCheck(state: .invalid, message: L.portTooLowMsg(lang), suggest: nil) }
    if n > 65535 { return PortCheck(state: .invalid, message: L.portTooHighMsg(lang), suggest: nil) }
    if occupied.contains(n) {
        var s = n + 1
        while occupied.contains(s) || s > 65535 { s = s > 65535 ? 1024 : s + 1 }
        return PortCheck(state: .occupied, message: LStr.portOccupied(v, lang), suggest: in_port_t(s))
    }
    return PortCheck(state: .ok, message: L.portOk(lang), suggest: nil)
}
