// 生成 app 图标（暖纸张 × 信号广播）：暖纸圆角方底 + 朱红 QR 定位方块 + 四角套准线。
// 纯 CoreGraphics/ImageIO（系统框架），可复现。用法：
//   swift tools/make-icon.swift            # 在仓库根目录运行
// 产物：AppIcon.iconset/（各尺寸 PNG）→ iconutil 合成 bundle/AppIcon.icns（脚本末尾自动调用）。
import AppKit
import CoreGraphics
import ImageIO
import Foundation

func draw(size S: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                        bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    func col(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    let paperTop = col(0.965, 0.945, 0.895)
    let paperBot = col(0.898, 0.855, 0.775)
    let signal   = col(0.823, 0.235, 0.090)   // #d23c17
    ctx.clear(CGRect(x: 0, y: 0, width: S, height: S))

    // 圆角方底（squircle 近似），留 6% 边距
    let inset = S * 0.06
    let rect = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let radius = (S - 2 * inset) * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: [paperTop, paperBot] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.setStrokeColor(col(0.122, 0.106, 0.086, 0.12))
    ctx.setLineWidth(max(1, S * 0.006))
    ctx.strokePath()
    ctx.restoreGState()

    // QR 定位方块：外圆角描边 + 内填充小方块
    let c = CGPoint(x: S / 2, y: S / 2)
    let outer = S * 0.50, lw = S * 0.072
    let outerRect = CGRect(x: c.x - outer / 2, y: c.y - outer / 2, width: outer, height: outer)
        .insetBy(dx: lw / 2, dy: lw / 2)
    ctx.addPath(CGPath(roundedRect: outerRect, cornerWidth: outer * 0.30, cornerHeight: outer * 0.30, transform: nil))
    ctx.setStrokeColor(signal); ctx.setLineWidth(lw); ctx.strokePath()

    let inner = S * 0.19
    let innerRect = CGRect(x: c.x - inner / 2, y: c.y - inner / 2, width: inner, height: inner)
    ctx.addPath(CGPath(roundedRect: innerRect, cornerWidth: inner * 0.32, cornerHeight: inner * 0.32, transform: nil))
    ctx.setFillColor(signal); ctx.fillPath()

    // 四角套准线（app 招牌细节），小尺寸省略
    if S >= 64 {
        let arm = S * 0.075, off = inset + S * 0.085
        ctx.setStrokeColor(col(0.122, 0.106, 0.086, 0.5))
        ctx.setLineWidth(max(1, S * 0.012)); ctx.setLineCap(.round)
        let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (off, S - off, arm, -arm), (S - off, S - off, -arm, -arm),
            (off, off, arm, arm),       (S - off, off, -arm, arm),
        ]
        for (x, y, dx, dy) in corners {
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x + dx, y: y))
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x, y: y + dy))
        }
        ctx.strokePath()
    }
    return ctx.makeImage()!
}

// iconset 尺寸 → 文件名
let names: [Int: [String]] = [
    16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"],
    64: ["icon_32x32@2x.png"], 128: ["icon_128x128.png"],
    256: ["icon_128x128@2x.png", "icon_256x256.png"],
    512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"],
]

let fm = FileManager.default
let iconset = "AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func writePNG(_ image: CGImage, to path: String) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

for (s, files) in names {
    let img = draw(size: CGFloat(s))
    for f in files { writePNG(img, to: "\(iconset)/\(f)") }
}
print("✅ AppIcon.iconset 已生成，合成 .icns…")

// 合成 .icns 并清理中间 iconset，一条命令即可重出图标
try? fm.createDirectory(atPath: "bundle", withIntermediateDirectories: true)
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "bundle/AppIcon.icns"]
try task.run(); task.waitUntilExit()
if task.terminationStatus == 0 {
    try? fm.removeItem(atPath: iconset)
    print("✅ bundle/AppIcon.icns 已生成")
} else {
    print("⚠️ iconutil 失败（保留 \(iconset) 以便排查）")
    exit(1)
}
