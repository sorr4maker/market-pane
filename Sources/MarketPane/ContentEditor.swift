import SwiftUI
import AppKit
import PaneCore
import PaneUI

/// 「编辑内容」窗口：增删、排序面板上的指数和汇率币种。只有一个，再点菜单就把它带到最前面。
/// 界面在 PaneUI 的 `ContentEditorView`（这里只负责开窗口、接上 AppModel）；所有改动立即生效，没有「保存」按钮。
@MainActor
final class ContentEditorController {
    private var window: NSWindow?

    func show(model: AppModel) {
        let win = window ?? makeWindow(model: model)
        window = win
        // 菜单栏 App 平时不是前台应用，不激活的话窗口会被别的应用盖住、输入框也收不到键盘
        NSApp.activate()
        win.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        win.title = "编辑内容"
        win.isReleasedWhenClosed = false   // 关掉只是收起来，下次还用同一个
        win.contentMinSize = NSSize(width: 440, height: 480)
        win.contentView = NSHostingView(rootView: ContentEditorRoot(model: model))
        win.setContentSize(NSSize(width: 520, height: 620))
        win.center()
        win.setFrameAutosaveName("MarketPaneContentEditor")
        return win
    }
}

/// 把 AppModel 的内容接给编辑界面：每次改动都在最新内容上做，再交给 `setContent` 保存、刷新
struct ContentEditorRoot: View {
    @ObservedObject var model: AppModel
    var body: some View {
        ContentEditorView(
            content: model.snapshot.settings.content,
            edit: { change in
                var next = model.snapshot.settings.content
                change(&next)
                model.setContent(next)
            },
            probe: { symbol, name in try await IndexService().probe(symbol: symbol, name: name) })
    }
}
