// swift-tools-version:5.9
// LocalShare（局域网文件分享）—— macOS 原生单窗口 app。
// 使用 Swift 5 语言模式（tools-version 5.9 默认）以放宽 Swift 6 的并发检查，
// 因为 Swifter 的请求处理回调运行在后台线程，严格并发会带来大量噪音。
import PackageDescription

let package = Package(
    name: "LocalShare",
    platforms: [.macOS(.v13)],
    dependencies: [
        // 纯 Swift 的轻量 HTTP server，SPM 源码编译进 app，不引入任何动态库依赖。
        .package(url: "https://github.com/httpswift/swifter.git", from: "1.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalShare",
            dependencies: [.product(name: "Swifter", package: "swifter")]
        ),
    ]
)
