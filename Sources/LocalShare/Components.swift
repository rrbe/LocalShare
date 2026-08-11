import SwiftUI

struct GlobeLineIcon: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color, lineWidth: 1.7)
            Ellipse().stroke(color, lineWidth: 1.6).frame(width: 7, height: 15)
            Capsule().fill(color).frame(width: 13, height: 1.6)
        }
        .frame(width: 15, height: 15)
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}
import AppKit

// 票据风 UI 组件库（DESIGN.md §5）。全部接受 `t: Theme` 显式传入（与设计稿 props 结构一一对应），
// 不依赖环境注入，渲染可预测。三种按钮语义不可混用：Primary 正向、Ghost 次级、Danger 破坏性。

// MARK: - 按钮

// 主按钮：实心 accent，白字，高 44，常 100% 宽。
struct PrimaryButton: View {
    let t: Theme
    var title: String
    var systemImage: String? = nil
    var fullWidth = true
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let s = systemImage { Image(systemName: s).font(.system(size: 15, weight: .bold)) }
                Text(title).font(.sans(14, .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 44)
            .padding(.horizontal, fullWidth ? 0 : 20)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.accent))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
            .shadow(color: .black.opacity(0.12), radius: 1, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// 幽灵按钮：透明底 + line 描边，hover 变 surfaceAlt / lineStrong。高 34。
struct GhostButton: View {
    let t: Theme
    var title: String
    var systemImage: String? = nil
    var fullWidth = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s).font(.system(size: 14, weight: .medium)) }
                Text(title).font(.sans(13, .semibold))
            }
            .foregroundStyle(t.ink)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: 34)
            .padding(.horizontal, 13)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? t.surfaceAlt : t.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? t.lineStrong : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// 危险按钮：实心 danger 红，白字。破坏性操作（停止分享）必须醒目，不可用 ghost。
struct DangerButton: View {
    let t: Theme
    var title: String
    var systemImage: String? = "stop.fill"
    var height: CGFloat = 34
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let s = systemImage { Image(systemName: s).font(.system(size: 13, weight: .bold)) }
                Text(title).font(.sans(13.5, .bold))
            }
            .foregroundStyle(.white)
            .frame(height: height)
            .padding(.horizontal, 16)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(t.danger))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hover ? 0.08 : 0)))
            .shadow(color: hover ? t.danger.opacity(0.35) : .black.opacity(0.18), radius: hover ? 7 : 1, x: 0, y: hover ? 4 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// 图标方钮：34×34，承载齿轮 / 帮助等单图标入口。
struct IconButton: View {
    let t: Theme
    var systemImage: String
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 15, weight: .medium))
                .foregroundStyle(t.ink)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? t.surfaceAlt : t.surface))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hover ? t.lineStrong : t.line, lineWidth: 1))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

// 所有页面头部常驻的宽屏切换；窗口状态由 AppState 统一维护，跨页面不丢。
struct WideLayoutButton: View {
    let t: Theme
    @EnvironmentObject var state: AppState
    var body: some View {
        IconButton(t: t,
                   systemImage: state.wideLayout ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                   help: state.wideLayout ? L.exitWide(state.lang) : L.expandWide(state.lang)) {
            state.toggleWideLayout()
        }
    }
}

// 低调 ✕ 小钮：hover 显淡底圆。票据卡用作「清除当前分享」，历史/最近行用作「删除这条记录」——
// 同一视觉语言，仅 help 文案随用途传入（默认「清除当前分享」）。
struct ClearButton: View {
    let t: Theme
    var lang: Lang
    var help: String? = nil
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover ? t.ink : t.inkFaint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? t.surfaceAlt : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }
        .help(help ?? L.clearShareHelp(lang))
    }
}

// MARK: - 状态胶囊 / 标签

// 广播 / 停止状态胶囊：状态点 + 文案 + 竖分隔 + :端口(mono)。
struct StatusPill: View {
    let t: Theme
    var running: Bool
    var host: String? = nil   // 运行中的局域网 IP；停止 / 无网络时留空，退回只显端口
    var port: in_port_t
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: running ? t.accent : t.inkFaint, live: running)
            address
                .font(.mono(12.5, .semibold)).lineLimit(1)
                .textSelection(.enabled)   // 整串 IP:端口 可拖选复制
        }
        .frame(height: 32).padding(.horizontal, 12)
        .background(Capsule().fill(t.surface))
        .overlay(Capsule().strokeBorder(t.line, lineWidth: 1))
    }
    // 运行且已知 IP → 「IP:端口」（如 192.168.31.18:8080），端口段染主色凸显「活」读数；
    // 否则退回「:端口」。状态另由左侧圆点颜色区分（亮 accent=服务中 / 灰=停止）。
    private var address: Text {
        let portStr = port == 0 ? "—" : String(port)
        if running, let host {
            return Text("\(host):").foregroundColor(t.ink)
                 + Text(portStr).foregroundColor(t.accent)
        }
        return Text(":\(portStr)").foregroundColor(t.ink)
    }
}

// 待命胶囊：空状态用，无脉冲。端口取「配置端口」作占位读数。
struct IdlePill: View {
    let t: Theme
    var label: String   // 由调用方传入已本地化文案
    var port: in_port_t
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(t.inkFaint).frame(width: 7, height: 7)
            Text(label).font(.sans(12.5, .semibold)).foregroundStyle(t.inkMute)
            Rectangle().fill(t.line).frame(width: 1, height: 14)
            Text(":\(String(port))").font(.mono(12.5, .semibold)).foregroundStyle(t.ink)
        }
        .frame(height: 32).padding(.horizontal, 12)
        .background(Capsule().fill(t.surface))
        .overlay(Capsule().strokeBorder(t.line, lineWidth: 1))
    }
}

// 权限标签胶囊：accent 态用 accentSoft 底，普通态透明底 + line 描边。
struct PermChip: View {
    let t: Theme
    var text: String
    var hot: Bool
    var body: some View {
        Text(text).font(.sans(11, .semibold))
            .foregroundStyle(hot ? t.accent : t.inkMute)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(hot ? t.accentSoft : .clear))
            .overlay(Capsule().strokeBorder(hot ? .clear : t.line, lineWidth: 1))
    }
}

// MARK: - 文件 / 文件夹标识

// 类型底色（DESIGN.md §5.5 TYPE_TINT）。深色模式底统一极淡白。
enum TypeTint {
    static func color(for c: FileCategory, dark: Bool) -> (bg: Color, fg: Color) {
        let fg: Color
        switch c {
        case .html:     fg = Color(hex: 0xc4451f)
        case .excel:    fg = Color(hex: 0x1f8a5b)
        case .image:    fg = Color(hex: 0x2a6fdb)
        case .pdf:      fg = Color(hex: 0xcf4444)
        case .markdown: fg = Color(hex: 0x7a5ae0)
        case .doc:      fg = Color(hex: 0xa9772a)
        case .slide:    fg = Color(hex: 0xb5562a)
        case .video:    fg = Color(hex: 0x2a6fdb)
        case .audio:    fg = Color(hex: 0x1f8a5b)
        case .archive:  fg = Color(hex: 0xa9772a)
        case .dir, .other: fg = Color(hex: 0x8c8475)
        }
        let bg = dark ? Color(hex: 0xffffff, alpha: 0.06) : fg.opacity(0.12)
        return (bg, fg)
    }
}

// 文件夹图标：圆角方块 + accentSoft 底 + accent 文件夹形。
struct FolderGlyph: View {
    let t: Theme
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(t.accentSoft)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "folder.fill").font(.system(size: size * 0.42)).foregroundStyle(t.accent))
    }
}

// 文本图标：圆角方块 + accentSoft 底 + accent 文本行形，表示「分享的一段文本」。
struct TextGlyph: View {
    let t: Theme
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(t.accentSoft)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "text.alignleft").font(.system(size: size * 0.4)).foregroundStyle(t.accent))
    }
}

// 多项图标：圆角方块 + accentSoft 底 + accent 叠放方块形，表示「多个文件/目录」。
struct MultiGlyph: View {
    let t: Theme
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(t.accentSoft)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "square.stack.3d.up.fill").font(.system(size: size * 0.42)).foregroundStyle(t.accent))
    }
}

// 文件类型图标：圆角方块 + 类型底色 + 类型 SF Symbol + 小写扩展名(mono)。
struct TypeGlyph: View {
    let t: Theme
    var category: FileCategory
    var ext: String = ""
    var size: CGFloat = 40
    var body: some View {
        let tint = TypeTint.color(for: category, dark: t.dark)
        return RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(tint.bg).frame(width: size, height: size)
            .overlay(
                VStack(spacing: 1) {
                    Image(systemName: category.sfSymbol).font(.system(size: size * 0.34))
                    if !ext.isEmpty {
                        Text(ext).font(.mono(size * 0.2, .semibold)).lineLimit(1)
                    }
                }
                .foregroundStyle(tint.fg)
                .padding(.horizontal, 3)
            )
    }
}

// MARK: - 开关

// 40×24 开关；locked 时降透明度且不可点（「读取与下载·始终开启」）。
struct ToggleSwitch: View {
    let t: Theme
    var isOn: Bool
    var locked = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: { if !locked { action() } }) {
            Capsule().fill(isOn ? t.accent : t.lineStrong)
                .frame(width: 40, height: 24)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 20, height: 20)
                        .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
                        .padding(2)
                }
                .opacity(locked ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .animation(.easeOut(duration: 0.18), value: isOn)
    }
}

// MARK: - 地址条

// 悬停高亮的图标小钮（CopyPill 内部用）。
struct HoverIcon: View {
    let t: Theme
    var systemImage: String
    var color: Color
    var help: String = ""
    var action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.system(size: 14, weight: .medium))
                .foregroundStyle(hover ? t.ink : color)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? t.surfaceAlt : .clear))
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(help)
    }
}

// 可复制地址条：field 底，左 mono 地址，右展开 + 复制（成功显示绿 check 1.3s）+ 浏览器打开。
// 折叠时中段省略；悬停 tooltip 与展开态都显示完整 URL（含 token）。
struct CopyPill: View {
    let t: Theme
    var lang: Lang
    var value: String
    var withOpen = true
    var compact = false
    var onOpen: (() -> Void)? = nil
    @State private var copied = false
    @State private var expanded = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                address.lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailingActions
            }
            HStack(alignment: expanded ? .top : .center, spacing: 4) {
                address
                    .lineLimit(expanded ? nil : 1).truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: expanded)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HoverIcon(t: t,
                          systemImage: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          color: t.inkMute,
                          help: expanded ? L.collapseAddress(lang) : L.expandAddress(lang)) { expanded.toggle() }
                trailingActions
            }
            .padding(.vertical, expanded ? 7 : 0)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: compact ? 42 : 48)
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(t.field))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(t.line, lineWidth: 1))
    }

    private var address: some View {
        Text(value).font(.mono(13)).foregroundStyle(t.ink)
            .padding(.leading, 12)
            .help(value)
    }

    @ViewBuilder private var trailingActions: some View {
        HoverIcon(t: t, systemImage: copied ? "checkmark" : "doc.on.doc",
                  color: copied ? t.ok : t.inkMute, help: L.copy(lang)) { copy() }
        if withOpen {
            HoverIcon(t: t, systemImage: "arrow.up.forward.square",
                      color: t.inkMute, help: L.openInBrowser(lang)) { onOpen?() }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
    }
}

// MARK: - 二维码卡

// 真实二维码（CoreImage 生成的 NSImage）渲染在白底圆角卡上，保留 padding 作静区。
// 始终白底，深色模式下也能扫。stopped 时灰显。
struct QRCard: View {
    var image: NSImage?
    var size: CGFloat = 172
    var dimmed = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).interpolation(.none).resizable()
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0xeeeeee))
                    .frame(width: size, height: size)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .shadow(color: Theme.castColor.opacity(0.08), radius: 12, x: 0, y: 8)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.4 : 1)
        .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

// MARK: - 票据卡

// 撕裂线：两侧半圆缺口(notch，bg 填充 + 越界被裁出镂空) + 中间虚线。
// zIndex 提到上层，保证 notch 的 bg 圆能盖住相邻内容、做出「咬掉一口」效果。
struct Perforation: View {
    let t: Theme
    var body: some View {
        Color.clear.frame(height: 1)
            .overlay(HLine().stroke(t.lineStrong, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4])).padding(.horizontal, 16))
            .overlay(alignment: .leading) { notch.offset(x: -9) }
            .overlay(alignment: .trailing) { notch.offset(x: 9) }
    }
    // 缺口填底色，再叠一层与卡片投影同源(castColor)的淡阴影：卡缘那圈底色本就被投影压暗，
    // 纯亮 t.bg 夹在其中会显成一块浮起的亮斑——压暗后半圆贴回底色，深浅主题各自成立。
    private var notch: some View {
        Circle().fill(t.bg).frame(width: 18, height: 18)
            .overlay(Circle().fill(Theme.castColor.opacity(0.05)))
            .overlay(Circle().strokeBorder(t.line, lineWidth: 1))
    }
}

// 登机牌式票据卡：上半「存根」(文件信息) + 撕裂线 + 下半「通行」(QR + 地址)。圆角 18、轻阴影。
struct TicketCard<Stub: View, Pass: View>: View {
    let t: Theme
    @ViewBuilder var stub: () -> Stub
    @ViewBuilder var pass: () -> Pass
    var body: some View {
        VStack(spacing: 0) {
            stub()
            Perforation(t: t).zIndex(1)
            pass()
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(t.surface))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(t.line, lineWidth: 1))
        .shadow(color: Theme.castColor.opacity(0.10), radius: 15, x: 0, y: 10)
    }
}

// 小节眼标：大写、加字距、inkMute（「监听端口 / 访问权限 / 最近分享」）。
struct SectionLabel: View {
    let t: Theme
    var text: String
    var body: some View {
        Text(text).font(.sans(11.5, .semibold)).tracking(0.6)
            .foregroundStyle(t.inkMute)
    }
}

// 分享对象的绝对路径行（mono，~ 缩写显示、超长中段省略）：hover 下划线 + 手型，
// 点按在 Finder 中定位；右侧按钮拷贝完整绝对路径（成功显示绿 check 1.3s）。
struct PathRow: View {
    let t: Theme
    var lang: Lang
    let url: URL
    let isFile: Bool
    @State private var hover = false
    @State private var copied = false
    private var pretty: String { (url.path as NSString).abbreviatingWithTildeInPath }
    var body: some View {
        HStack(spacing: 6) {
            // 不再画文件/文件夹小图标：上方大类型图标已表明类型，此处重复。
            Text(pretty)
                .font(.mono(10.5)).foregroundStyle(t.inkFaint.opacity(hover ? 1 : 0.85))
                .underline(hover, color: t.inkFaint)
                .lineLimit(1).truncationMode(.middle)
                .contentShape(Rectangle())
                .onTapGesture { reveal() }
                .onHover { h in hover = h; if h { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                .help(isFile ? L.revealFileHelp(lang) : L.openFolderHelp(lang))
            Spacer(minLength: 6)
            Button { copyPath() } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(copied ? t.ok : t.inkFaint)
                    .frame(width: 16, height: 16)   // 固定框：checkmark 与 doc.on.doc 字形高度不同，不锁尺寸整行会抖一下
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(L.copyPathHelp(lang))
        }
    }
    private func reveal() {
        if isFile { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(url) }
    }
    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { copied = false }
    }
}
