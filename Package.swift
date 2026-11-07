// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreakTrigger",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BreakTrigger", targets: ["BreakTrigger"]),
    ],
    targets: [
        // 作業時間の計測と通知の判定。UIやOSのAPIに依存しない
        .target(name: "BreakTriggerCore"),
        // メニューバー、通知、設定画面
        .executableTarget(name: "BreakTrigger", dependencies: ["BreakTriggerCore"]),
        .testTarget(name: "BreakTriggerCoreTests", dependencies: ["BreakTriggerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
