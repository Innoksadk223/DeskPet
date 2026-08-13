import AppKit

/// 桌宠宿主窗口：无边框、透明、置顶、不抢焦点、全空间/全屏可见。
/// M0 规格（plan.md §5.2）：
/// - styleMask: [.borderless, .nonactivatingPanel]
/// - level = .floating；isOpaque = false；backgroundColor = .clear
/// - hidesOnDeactivate = false（失活不隐藏）
/// - collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
/// - 拖拽由 PetView 自定义实现（mouseDown/mouseDragged 改 frame 原点）
final class PetPanel: NSPanel {
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // 透明面板的阴影会框出矩形残影，桌宠本体不需要
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = false // 自定义拖拽
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
    }

    /// 桌宠永远不抢键盘焦点；文字输入走独立输入面板（临时激活）。
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
