import SwiftUI
import PaneCore

@main
struct MarketPaneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra("行情窗", systemImage: "chart.line.uptrend.xyaxis") {
            Toggle("显示桌面面板", isOn: $model.showPanel)
            PanelMenuItems(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// 菜单栏图标和面板右键菜单共用的项目。
/// 右键菜单里不放「隐藏面板」：菜单栏图标可能被挤掉看不到，隐藏后就找不回来了。
struct PanelMenuItems: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Toggle("编辑布局（拖动、调整大小）", isOn: $model.editingLayout)
        Button("编辑内容（指数、汇率）…") { model.showContentEditor() }
        Button(model.isRefreshing ? "刷新中…" : "立即刷新") { Task { await model.refresh(force: true) } }
            .disabled(model.isRefreshing)
        Divider()
        Toggle("红涨绿跌", isOn: Binding(get: { model.snapshot.settings.upIsRed }, set: model.setUpIsRed))
        Toggle("开机自动启动", isOn: Binding(get: { model.launchAtLogin }, set: model.setLaunchAtLogin))
        Divider()
        Text(model.lastRefreshed.map { "更新于 \($0.formatted(date: .omitted, time: .shortened))" } ?? "尚未刷新")
        Button("退出行情窗") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}

/// 面板被隐藏、菜单栏图标又找不到时的保险：在「应用程序」里再打开一次行情窗，面板就重新显示。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showPanel = true }
        return true
    }
}
