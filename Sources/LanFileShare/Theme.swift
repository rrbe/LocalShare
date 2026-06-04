import SwiftUI

// MARK: - 设计系统：暖纸张 × 信号广播
// 把「选文件夹 → 出二维码」重新想象成「把一个文件夹播到本地网络上」——
// 二维码是信号源、IP:端口是频率、运行中即「广播中」。任意同网设备(手机/电脑/平板)调到这个地址即可收看。
// 颜色 / 字体 / 氛围层 / 通用组件集中在此，保证全局视觉一致；只用系统字体，零外部依赖。

enum Palette {
    static let paper     = Color(.sRGB, red: 0.945, green: 0.926, blue: 0.884, opacity: 1) // 暖骨白·底
    static let paperEdge = Color(.sRGB, red: 0.882, green: 0.843, blue: 0.773, opacity: 1) // 暗角
    static let surface   = Color(.sRGB, red: 0.989, green: 0.978, blue: 0.953, opacity: 1) // 卡片 / 高光
    static let ink       = Color(.sRGB, red: 0.122, green: 0.106, blue: 0.086, opacity: 1) // 主文字
    static let inkSoft   = Color(.sRGB, red: 0.404, green: 0.369, blue: 0.318, opacity: 1) // 次文字
    static let signal    = Color(.sRGB, red: 0.851, green: 0.243, blue: 0.090, opacity: 1) // 朱红·信号强调
    static let line      = Color(.sRGB, red: 0.122, green: 0.106, blue: 0.086, opacity: 0.14)
}

extension Font {
    // 衬线刊头：拉丁走 New York、中文回落系统宋体，编辑感。
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    // 等宽技术读数：IP / 端口 / 链接，SF Mono。
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 氛围层

// 纸张背景：暖光晕 + 暗角 + 颗粒噪点，铺满整窗（含隐藏标题栏区域）。
struct PaperBackground: View {
    var body: some View {
        ZStack {
            Palette.paper
            RadialGradient(colors: [Palette.surface.opacity(0.95), .clear],
                           center: .init(x: 0.5, y: 0.16), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [.clear, Palette.paperEdge.opacity(0.6)],
                           center: .center, startRadius: 230, endRadius: 560)
            GrainOverlay().opacity(0.06)
        }
        .ignoresSafeArea()
    }
}

// 颗粒噪点：用确定性伪随机撒一层极淡墨点，给纸张质感。固定种子 → 仅尺寸变化时重绘。
struct GrainOverlay: View {
    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                return Double(seed % 10_000) / 10_000.0
            }
            let count = Int(size.width * size.height / 1100)
            for _ in 0..<count {
                let x = next() * size.width
                let y = next() * size.height
                let r = 0.5 + next() * 0.7
                let a = 0.22 + next() * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: r, height: r)),
                         with: .color(Palette.ink.opacity(a)))
            }
        }
        .allowsHitTesting(false)
        .blendMode(.multiply)
    }
}

// 电波环：从信号源向外持续扩散的同心环，传达「正在广播」。
struct BroadcastRings: View {
    @State private var animate = false
    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Palette.signal.opacity(0.45), lineWidth: 1.1)
                    .scaleEffect(animate ? 2.05 : 0.92)
                    .opacity(animate ? 0 : 0.5)
                    .animation(.easeOut(duration: 3.4).repeatForever(autoreverses: false)
                        .delay(Double(i) * 1.13), value: animate)
            }
        }
        .onAppear { animate = true }
        .allowsHitTesting(false)
    }
}

// 实时状态点：广播中时外圈呼吸扩散，停机时为静态灰点。
struct LiveDot: View {
    var color: Color
    var live: Bool
    @State private var pulse = false
    var body: some View {
        ZStack {
            if live {
                Circle()
                    .stroke(color.opacity(0.65), lineWidth: 1)
                    .scaleEffect(pulse ? 2.7 : 1)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(.easeOut(duration: 1.9).repeatForever(autoreverses: false), value: pulse)
            }
            Circle().fill(color).frame(width: 7, height: 7)
        }
        .frame(width: 7, height: 7)
        .onAppear { pulse = true }
    }
}

// 套准角标：二维码四角的印刷裁切线，编辑/印刷质感。
struct CropMarks: View {
    var color: Color
    var arm: CGFloat = 12
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            Path { p in
                func corner(_ x: CGFloat, _ y: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
                    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + dx, y: y))
                    p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x, y: y + dy))
                }
                corner(0, 0, arm, arm)
                corner(w, 0, -arm, arm)
                corner(0, h, arm, -arm)
                corner(w, h, -arm, -arm)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 交互组件

// 主按钮：朱红信号填充。
struct SignalButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Palette.surface)
            .padding(.horizontal, 24).padding(.vertical, 11)
            .background(Palette.signal)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

// 幽灵按钮：墨色描边，次要操作。
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 15).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

// 图标方钮：复制 / 打开。
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Palette.inkSoft)
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Palette.line, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

// 悬停轻抬：鼠标移入时微放大。
struct HoverLift: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(hover ? 1.05 : 1)
            .animation(.easeOut(duration: 0.16), value: hover)
            .onHover { hover = $0 }
    }
}

// 入场：错落淡入上浮。
struct Enter: ViewModifier {
    let appeared: Bool
    let delay: Double
    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.easeOut(duration: 0.55).delay(delay), value: appeared)
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
    func enter(_ appeared: Bool, _ delay: Double) -> some View { modifier(Enter(appeared: appeared, delay: delay)) }
}
