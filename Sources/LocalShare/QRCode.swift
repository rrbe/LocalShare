import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

// 用系统自带的 CoreImage CIQRCodeGenerator 生成二维码，无需任何第三方库。
enum QRCode {
    static func image(for string: String, scale: CGFloat = 12) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M" // 容错级别 M，兼顾密度与可靠性

        guard let output = filter.outputImage else { return nil }
        // 原始输出每个码点只有 1pt，需放大才清晰
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    // 终端二维码（headless 模式）：半块字符 ▀ 把上下两行码点并作一行（上半=前景、下半=背景），
    // ANSI 颜色写死黑码白底，深色/浅色终端都保持可扫；外圈补 2 个码点的静区。
    static func ansi(for string: String) -> String? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        // 原始输出 1pt = 1 码点，逐像素读灰度即得码点矩阵（深≈0、浅≈255）。
        let w = Int(output.extent.width), h = Int(output.extent.height)
        guard w > 0, h > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h)
        CIContext().render(output, toBitmap: &pixels, rowBytes: w,
                           bounds: output.extent, format: .L8,
                           colorSpace: CGColorSpaceCreateDeviceGray())

        let quiet = 2
        let cols = w + quiet * 2, rows = h + quiet * 2
        func dark(_ x: Int, _ y: Int) -> Bool {
            let px = x - quiet, py = y - quiet
            guard (0..<w).contains(px), (0..<h).contains(py) else { return false }
            return pixels[py * w + px] < 128
        }

        var out = ""
        var y = 0
        while y < rows {
            for x in 0..<cols {
                let fg = dark(x, y) ? 30 : 97        // 上半行：黑 / 亮白前景
                let bg = dark(x, y + 1) ? 40 : 107   // 下半行：黑 / 亮白背景（越界视为浅）
                out += "\u{1B}[\(fg);\(bg)m▀"
            }
            out += "\u{1B}[0m\n"
            y += 2
        }
        return out
    }
}
