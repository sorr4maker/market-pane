import SwiftUI
import AppKit
import PaneCore
import PaneUI

/// 详情窗口（指数或汇率的 K 线）：只有一个，点别的行时换内容。第一次出现在桌面面板左边，之后记住你拖到的位置。Esc 关闭。
@MainActor
final class DetailWindowController {
    private var window: NSWindow?

    func show(spec: IndexSpec, model: AppModel, beside panelFrame: NSRect?) {
        present(title: spec.name, beside: panelFrame) { close in AnyView(DetailRoot(model: model, spec: spec, close: close)) }
    }

    func show(fx pair: FXPairSpec, model: AppModel, beside panelFrame: NSRect?) {
        present(title: pair.title, beside: panelFrame) { close in AnyView(FXDetailRoot(model: model, pair: pair, close: close)) }
    }

    private func present(title: String, beside panelFrame: NSRect?, content: (@escaping () -> Void) -> AnyView) {
        let win = window ?? makeWindow()
        let firstTime = window == nil
        window = win
        let host = NSHostingView(rootView: content({ [weak win] in win?.close() }))
        win.contentView = host
        win.title = title
        win.setContentSize(host.fittingSize)
        if firstTime && !win.setFrameUsingName("MarketPaneDetail") {
            place(win, beside: panelFrame)
        }
        win.setFrameAutosaveName("MarketPaneDetail")
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
                           styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.moveToActiveSpace]
        return win
    }

    /// 放在面板左边、顶部对齐；左边放不下就放在屏幕中间
    private func place(_ win: NSWindow, beside panel: NSRect?) {
        guard let panel, let screen = NSScreen.screens.first(where: { $0.frame.intersects(panel) }) ?? NSScreen.main else {
            win.center(); return
        }
        let size = win.frame.size, visible = screen.visibleFrame
        let x = panel.minX - size.width - 16
        guard x >= visible.minX else { win.center(); return }
        let y = min(max(panel.maxY - size.height, visible.minY), visible.maxY - size.height)
        win.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct DetailRoot: View {
    @ObservedObject var model: AppModel
    let spec: IndexSpec
    let close: () -> Void

    var body: some View {
        // 每 30 秒重画：头部的价格和「交易中 / 已收盘」跟着面板的数据走
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            IndexDetailView(
                spec: spec, quote: model.snapshot.indices?.quote(spec.id), now: ctx.date,
                upIsRed: model.snapshot.settings.upIsRed,
                load: { [chart = model.chartService, symbol = spec.yahooSymbol] period, force in
                    try await chart.series(symbol: symbol, period: period, force: force)
                },
                onOpenExternal: { NSWorkspace.shared.open(spec.yahooPageURL) })
        }
        .padding(.top, 14)   // 透明标题栏下面留出关闭按钮的位置
        .background(Button("关闭", action: close).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false))
    }
}

private struct FXDetailRoot: View {
    @ObservedObject var model: AppModel
    let pair: FXPairSpec
    let close: () -> Void

    var body: some View {
        FXDetailView(
            pair: pair, upIsRed: model.snapshot.settings.upIsRed,
            load: { [chart = model.chartService] period, force in try await FXCross.load(pair, period: period, service: chart, force: force) },
            onOpenExternal: {
                let symbol = pair.isDirect ? (pair.legs.first?.yahooSymbol ?? "") : "\(pair.from)\(pair.to)=X"
                if let url = URL(string: "https://finance.yahoo.com/quote/\(symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? symbol)/") {
                    NSWorkspace.shared.open(url)
                }
            })
            .padding(.top, 14)
            .background(Button("关闭", action: close).keyboardShortcut(.cancelAction).opacity(0).allowsHitTesting(false))
    }
}
