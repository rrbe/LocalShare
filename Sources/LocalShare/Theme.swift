import SwiftUI

// MARK: - 设计系统：暖奶油底 × 砖红强调 · 票据风
// 权威规范见 DESIGN.md。所有颜色由 Theme 统一生成，支持浅 / 深色双主题；
// 强调色默认砖红橙 #df4f28。字族严格分工：标题 display(衬线)、正文 sans、技术信息 mono。
// 设计 DNA：克制、安静、像一张实体票据 —— 不渐变、不 emoji、不彩色光晕。零外部依赖（仅系统字体/框架）。

struct Theme: Equatable {
    // 强调
    var accent: Color
    var accentSoft: Color
    // 中性
    var bg: Color
    var surface: Color
    var surfaceAlt: Color
    var field: Color
    // 文字
    var ink: Color
    var inkMute: Color
    var inkFaint: Color
    // 线 / 描边
    var line: Color
    var lineStrong: Color
    // 语义
    var ok: Color
    var danger: Color
    var warn: Color
    // 主题标记
    var dark: Bool

    // 默认强调色（砖红橙）。DESIGN.md §1.1 可选项：#df4f28 / #2a6fdb / #1f8a5b / #7a5ae0。
    static let brickRed = Color(hex: 0xdf4f28)

    // 票据卡阴影色：rgba(40,30,15,·)
    static let castColor = Color(hex: 0x281e0f)

    static func make(dark: Bool, accent: Color = brickRed) -> Theme {
        dark
            ? Theme(
                accent: accent,
                accentSoft: Color(hex: 0xdf4f28, alpha: 0.18),
                bg: Color(hex: 0x1b1814),
                surface: Color(hex: 0x262219),
                surfaceAlt: Color(hex: 0x211e16),
                field: Color(hex: 0x1d1a14),
                ink: Color(hex: 0xf2eee5),
                inkMute: Color(hex: 0xa59d8c),
                inkFaint: Color(hex: 0x6d675a),
                line: Color(hex: 0x37322a),
                lineStrong: Color(hex: 0x494238),
                ok: Color(hex: 0x2f9e57),
                danger: Color(hex: 0xef8a6e),
                warn: Color(hex: 0xe0a83a),
                dark: true)
            : Theme(
                accent: accent,
                accentSoft: Color(hex: 0xdf4f28, alpha: 0.12),
                bg: Color(hex: 0xefeae1),
                surface: Color(hex: 0xfdfbf7),
                surfaceAlt: Color(hex: 0xf5f0e7),
                field: Color(hex: 0xefe9de),
                ink: Color(hex: 0x2a261d),
                inkMute: Color(hex: 0x8c8475),
                inkFaint: Color(hex: 0xb4ab99),
                line: Color(hex: 0xe7dfd1),
                lineStrong: Color(hex: 0xdacfbd),
                ok: Color(hex: 0x2f9e57),
                danger: Color(hex: 0xc43c1c),
                warn: Color(hex: 0xb67708),
                dark: false)
    }
}

extension Color {
    // 0xRRGGBB → Color；alpha 另传。集中一处，避免散落的浮点 RGB。
    init(hex: UInt, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }
}

extension Font {
    // 标题：拉丁走衬线、中文回落系统宋体（Source Serif 4 同语感）。
    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    // 正文 / 控件。
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    // 技术读数：IP / 端口 / URL / 路径 / 体积 / 项数 / 日期。
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 基础形状 / 动效

// 水平线（票据撕裂虚线用）。
struct HLine: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// 状态圆点：live 时外圈呼吸扩散（对应设计 lsPulse 1.8s ease-out 无限）。
struct StatusDot: View {
    var color: Color
    var live: Bool
    var size: CGFloat = 7
    @State private var pulse = false
    var body: some View {
        ZStack {
            if live {
                Circle()
                    .fill(color.opacity(0.5))
                    .scaleEffect(pulse ? 2.6 : 1)
                    .opacity(pulse ? 0 : 0.6)
                    .animation(.easeOut(duration: 1.8).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .onAppear { pulse = true }
    }
}
