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
        // Sparkle 自动更新。注意：它不是纯源码包，而是二进制 framework（binaryTarget），
        // 会以 Sparkle.framework 内置进 .app/Contents/Frameworks（随包走、运行时不缺失），
        // 不依赖任何包外 dylib——这正是放宽「零 dylib」戒律的边界（见 PLAN.md §0）。
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "LocalShare",
            dependencies: [
                .product(name: "Swifter", package: "swifter"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // 让主二进制能在 .app 内找到内置 framework：
                //   Contents/MacOS/LocalShare → ../Frameworks = Contents/Frameworks
                // build.sh 会把 Sparkle.framework 拷进 Contents/Frameworks。
                // （swift run/test 时 SPM 另有指向 .build/artifacts 的 rpath，故本地裸跑也能加载。）
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        // 单元测试：@testable import 可执行 target，无须把源码拆成单独 library、也无须把
        // internal 符号提成 public——直接测纯函数（防穿越判据、文件名清洗、key 去重等）。
        .testTarget(
            name: "LocalShareTests",
            dependencies: ["LocalShare"]
        ),
    ]
)
