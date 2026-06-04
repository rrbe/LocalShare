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
}
