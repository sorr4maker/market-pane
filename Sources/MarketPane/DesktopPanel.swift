import SwiftUI
import AppKit
import PaneCore
import PaneUI

/// 贴在桌面上的面板：在桌面图标之上、所有普通窗口之下，所有桌面空间都显示。
/// 平时锁定；菜单里点「编辑布局」后才能拖动和拖右下角调整大小，编辑时暂时浮到其他窗口上面。
/// 位置和大小用 autosave 记住，下次启动还原。
@MainActor
final class DesktopPanelController {
    private var window: NSPanel?
    private var resizeObserver: NSObjectProtocol?
    private static let desktopLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private static let autosaveName = "MarketPanePanel"
    /// 上次的位置和大小。不能用 `setFrameUsingName`：无边框、不可调整的窗口它只还原位置、不还原大小。
    /// AppKit 存的格式是「x y 宽 高 屏幕x 屏幕y 屏幕宽 屏幕高」。
    private static func savedFrame() -> NSRect? {
        guard let s = UserDefaults.standard.string(forKey: "NSWindow Frame \(autosaveName)") else { return nil }
        let n = s.split(separator: " ").compactMap { Double($0) }
        guard n.count >= 4, n[2] > 0, n[3] > 0 else { return nil }
        return NSRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }

    /// 面板当前位置（详情窗口贴着它摆）
    var frame: NSRect? { window?.isVisible == true ? window?.frame : nil }

    func setVisible(_ visible: Bool, model: AppModel) {
        if !visible { window?.orderOut(nil); return }
        let panel = window ?? makePanel(model: model)
        window = panel
        panel.orderFrontRegardless()
        keepOnScreen(panel)
    }

    func setEditing(_ on: Bool, model: AppModel) {
        guard let panel = window else { return }
        panel.level = on ? .floating : Self.desktopLevel
        updateSizeLimits(panel, model: model)
        keepOnScreen(panel)
        panel.orderFrontRegardless()
    }

    /// 内容（指数、币种、表）变了：重新量每一档需要的大小，更新上下限，把超限的窗口收回来
    func contentChanged(model: AppModel) {
        guard let panel = window else { return }   // 面板还没建过：建的时候会按新内容量
        model.panelTiers = AdaptivePanel.idealSizes(snapshot: model.snapshot, now: Date())
        updateSizeLimits(panel, model: model)
        clampSize(panel)
        keepOnScreen(panel)
    }

    private func makePanel(model: AppModel) -> NSPanel {
        let tiers = AdaptivePanel.idealSizes(snapshot: model.snapshot, now: Date())
        model.panelTiers = tiers
        let base = tiers[0]
        let host = FirstMouseHostingView(rootView: DesktopPanelRoot(model: model))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: base),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = Self.desktopLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = host
        updateSizeLimits(panel, model: model)
        if let saved = Self.savedFrame() {
            panel.setFrame(saved, display: false)
        } else if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrame(NSRect(x: v.maxX - base.width - 24, y: v.maxY - base.height - 24, width: base.width, height: base.height), display: false)
        }
        panel.setFrameAutosaveName(Self.autosaveName)
        clampSize(panel)
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) {
            [weak self, weak panel] _ in
            MainActor.assumeIsolated { if let panel { self?.keepOnScreen(panel) } }
        }
        return panel
    }

    /// 最小：最紧凑那一档缩到 0.75 倍；最大：完整内容放大 1.8 倍，且不超过屏幕
    private func updateSizeLimits(_ panel: NSPanel, model: AppModel) {
        let v = (panel.screen ?? NSScreen.main)?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let compact = model.panelTiers.last ?? .zero, full = model.panelTiers.first ?? .zero
        let lo = PaneScale.minSize(compact: (compact.width, compact.height))
        let hi = PaneScale.maxSize(full: (full.width, full.height), screenWidth: v.width, screenHeight: v.height)
        panel.minSize = CGSize(width: lo.width, height: lo.height)
        panel.maxSize = CGSize(width: max(hi.width, lo.width), height: max(hi.height, lo.height))
    }

    /// 记住的大小超出上下限（比如换了更小的屏幕）时收回来，左上角不动
    private func clampSize(_ panel: NSPanel) {
        var f = panel.frame
        let w = min(max(f.width, panel.minSize.width), panel.maxSize.width)
        let h = min(max(f.height, panel.minSize.height), panel.maxSize.height)
        guard w != f.width || h != f.height else { return }
        f.origin.y += f.height - h; f.size = CGSize(width: w, height: h)
        panel.setFrame(f, display: true)
    }

    /// 记住的位置是按左上角存的：面板变大或换了更小的屏幕时，右边、下边会跑出屏幕，挪回来。
    private func keepOnScreen(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let v = screen.visibleFrame
        var f = panel.frame
        if f.maxX > v.maxX { f.origin.x = max(v.minX, v.maxX - f.width - 24) }
        if f.minX < v.minX { f.origin.x = v.minX }
        if f.maxY > v.maxY { f.origin.y = v.maxY - f.height }
        if f.minY < v.minY { f.origin.y = v.minY }
        if f.origin != panel.frame.origin { panel.setFrameOrigin(f.origin) }
    }
}

struct DesktopPanelRoot: View {
    @ObservedObject var model: AppModel
    var body: some View {
        // 每 30 秒重画一次：交易中/已收盘的状态和标题栏时间跟着走（数据本身由 AppModel 定时抓）
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            AdaptivePanel(snapshot: model.snapshot, now: ctx.date, tierSizes: model.panelTiers,
                          // 编辑布局时点行不弹详情，整块都用来拖
                          onSelectIndex: model.editingLayout ? nil : { model.showDetail($0) },
                          onSelectFX: model.editingLayout ? nil : { model.showFXDetail($0) })
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { PanelBorder() }
        .overlay { if model.editingLayout { EditLayoutOverlay { model.editingLayout = false } } }
        // 右键面板：和菜单栏图标一样的菜单（菜单栏太挤时图标会被系统藏起来）
        .contextMenu { PanelMenuItems(model: model) }
    }
}

/// 编辑布局时盖在面板上：虚线边框、「完成」按钮、右下角缩放手柄，其余地方按住就能拖动整个面板
struct EditLayoutOverlay: View {
    let done: () -> Void
    var body: some View {
        ZStack {
            MoveSurface()
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .allowsHitTesting(false)
            VStack {
                HStack {
                    Spacer()
                    Button("完成", action: done).buttonStyle(.borderedProminent).controlSize(.small)
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Text("按住拖动 · 拖右下角调整大小")
                        .font(.system(size: 11)).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .allowsHitTesting(false)
                    Spacer()
                    ResizeGrip().frame(width: 22, height: 22)
                }
            }
            .padding(10)
        }
    }
}

/// 按住任意位置拖动窗口
struct MoveSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class View: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// 右下角缩放手柄：拖动时左上角不动，大小限制在窗口的 minSize / maxSize 之间
struct ResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Grip() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Grip: NSView {
        private var startFrame: NSRect = .zero
        private var startMouse: NSPoint = .zero

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setStroke()
            for i in 0..<3 {
                let d = CGFloat(i) * 5 + 5
                let p = NSBezierPath()
                p.move(to: NSPoint(x: bounds.maxX - d, y: bounds.minY + 2))
                p.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.minY + d))
                p.lineWidth = 1.5
                p.stroke()
            }
        }

        override func resetCursorRects() {
            if #available(macOS 15.0, *) {
                addCursorRect(bounds, cursor: .frameResize(position: .bottomRight, directions: .all))
            } else {
                addCursorRect(bounds, cursor: .crosshair)
            }
        }

        override func mouseDown(with event: NSEvent) {
            startFrame = window?.frame ?? .zero
            startMouse = NSEvent.mouseLocation
        }

        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let p = NSEvent.mouseLocation
            let width = min(max(startFrame.width + (p.x - startMouse.x), w.minSize.width), w.maxSize.width)
            let height = min(max(startFrame.height - (p.y - startMouse.y), w.minSize.height), w.maxSize.height)
            w.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
        }
    }
}

/// 面板不会变成活动窗口：第一下点击就要直接生效（点指数行），而不是先被系统拿去「激活窗口」
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
