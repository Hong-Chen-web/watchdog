// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Watchdog",
    platforms: [.macOS(.v13)],
    targets: [
        // 核心库:主题/组件/模型/API/布局/卡片——全部可单测
        .target(name: "WatchdogCore", path: "Sources/WatchdogCore"),
        // 可执行壳:仅 sidecar 管理 + AppDelegate + 入口
        .executableTarget(name: "Watchdog", dependencies: ["WatchdogCore"], path: "Sources/Watchdog"),
        // 测试:纯逻辑单测 + 真实接口夹具解码回归
        .testTarget(name: "WatchdogTests", dependencies: ["WatchdogCore"], path: "Tests/WatchdogTests",
                    resources: [.copy("Fixtures")]),
    ]
)
