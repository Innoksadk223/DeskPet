// swift-tools-version:5.10
// DeskPet M0 —— 桌宠壳（Swift/AppKit 纯代码，无 storyboard / xib / 资源 bundle）
import PackageDescription

let package = Package(
    name: "DeskPet",
    platforms: [
        // NSImage/CGImageSource 对 webp 的 ImageIO 支持需要 macOS 11+
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "DeskPet",
            path: "Sources/DeskPet"
        )
    ]
)
