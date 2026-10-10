import SwiftUI
import ServiceManagement
import PaneCore

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var snapshot: PaneSnapshot
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var isRefreshing = false
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var showPanel: Bool {
        didSet {
            UserDefaults.standard.set(showPanel, forKey: "showPanel")
            if !showPanel { editingLayout = false }
            panel.setVisible(showPanel, model: self)
        }
    }
    /// 编辑布局：只有这时面板才能拖动、调整大小（用户选的：平时锁定，免得误拖）
    @Published var editingLayout = false {
        didSet {
            guard editingLayout != oldValue else { return }
            if editingLayout && !showPanel { showPanel = true }
            panel.setEditing(editingLayout, model: self)
        }
    }
    /// 面板每一档排版（`PaneStyle.tiers`）在 1 倍时的大小，面板按它选档位、算缩放；打开面板时量一次
    var panelTiers = [CGSize(width: 606, height: 423)]

    private let store = SnapshotStore.default()
    private let indexService = IndexService()
    private let fxService = FXService()
    private let panel = DesktopPanelController()
    private let detail = DetailWindowController()
    /// 详情图的走势按需抓、带缓存
    let chartService = ChartService()
    private let editor = ContentEditorController()
    private var loop: Task<Void, Never>?
    private var rerunForced = false

    private init() {
        snapshot = store.load() ?? PaneSnapshot(generatedAt: Date())
        showPanel = UserDefaults.standard.object(forKey: "showPanel") as? Bool ?? true
        panel.setVisible(showPanel, model: self)
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: false)
                try? await Task.sleep(for: .seconds(30))   // 抓不抓由 RefreshPolicy 决定
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.refresh(force: true) }
        }
    }

    /// 指数：有市场在交易时约每分钟一次，都休市时 5 分钟一次；汇率：前一天的收盘，换日才抓。
    /// 正在抓的时候又来了强制刷新（比如刚改了内容），等这轮结束后再来一轮，不丢。
    func refresh(force: Bool) async {
        if isRefreshing {
            if force { rerunForced = true }
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        var force = force
        repeat {
            rerunForced = false
            await refreshOnce(force: force)
            force = true
        } while rerunForced
        lastRefreshed = Date()
    }

    private func refreshOnce(force: Bool) async {
        let now = Date()
        let content = snapshot.settings.content
        if force || RefreshPolicy.indicesDue(snapshot.indices, now: now) {
            let fresh = await indexService.fetch(asOf: now, specs: content.indices)
            update { $0.indices = fresh.merging(previous: $0.indices, ids: content.indices.map(\.id)) }
        }
        if force || RefreshPolicy.fxDue(snapshot.fx, now: now, codes: content.currencies) {
            let fresh = await fxService.fetch(asOf: now, codes: content.currencies)
            update { $0.fx = fresh.merging(previous: $0.fx, codes: content.currencies) }
        }
    }

    /// 「编辑内容」改了指数、币种或表：保存、按新内容重新量面板各档大小，再抓一遍数据。
    /// 只是调顺序、开关某张表时不用重新抓（数据一样，面板按新顺序画就行）。
    func setContent(_ content: PaneContent) {
        let old = snapshot.settings.content
        guard content != old else { return }
        update { $0.settings.content = content }
        panel.contentChanged(model: self)
        objectWillChange.send()
        let sameData = old.indices.map(\.id).sorted() == content.indices.map(\.id).sorted()
            && old.currencies.sorted() == content.currencies.sorted()
        if !sameData { Task { await refresh(force: true) } }
    }

    /// 打开「编辑内容」窗口
    func showContentEditor() { editor.show(model: self) }

    func setUpIsRed(_ v: Bool) { update { $0.settings.upIsRed = v } }

    /// 点面板上的指数行：打开（或切换到）这个指数的走势窗口
    func showDetail(_ spec: IndexSpec) { detail.show(spec: spec, model: self, beside: panel.frame) }
    func showFXDetail(_ pair: FXPairSpec) { detail.show(fx: pair, model: self, beside: panel.frame) }

    func setLaunchAtLogin(_ on: Bool) {
        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
        catch { NSLog("开机自启设置失败：\(error)") }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// 基于「此刻」的快照修改后保存；内容没变就不写盘。
    private func update(_ change: (inout PaneSnapshot) -> Void) {
        var next = snapshot
        change(&next)
        next.generatedAt = snapshot.generatedAt
        guard next != snapshot else { return }
        next.generatedAt = Date()
        snapshot = next
        do { try store.save(next) } catch { NSLog("写入快照失败：\(error)") }
    }
}
