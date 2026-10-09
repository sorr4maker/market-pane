// swift-tools-version: 6.0
import PackageDescription

// 行情窗 MarketPane：菜单栏 + 桌面面板。
// 检查用可执行目标 PaneChecks（`swift run PaneChecks`，失败退出码非 0），不依赖 XCTest。
let package = Package(
    name: "MarketPane",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "PaneCore"),
        .target(name: "PaneUI", dependencies: ["PaneCore"]),
        .executableTarget(name: "MarketPane", dependencies: ["PaneCore", "PaneUI"]),
        .executableTarget(name: "PaneChecks", dependencies: ["PaneCore"]),
        // 把原生界面渲染成 PNG，用来在看不到桌面的情况下检查排版
        .executableTarget(name: "PaneSnapshots", dependencies: ["PaneCore", "PaneUI"]),
    ],
    swiftLanguageModes: [.v5]
)
