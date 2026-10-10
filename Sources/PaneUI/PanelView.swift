import SwiftUI
import AppKit
import PaneCore

/// 桌面面板的内容（全部原生绘制）。排版档位和缩放比例从环境里的 `paneStyle` 读。
public struct PanelView: View {
    let snapshot: PaneSnapshot
    let now: Date
    let draggable: Bool
    let onSelectIndex: ((IndexSpec) -> Void)?
    let onSelectFX: ((FXPairSpec) -> Void)?
    @Environment(\.paneStyle) private var st

    public init(snapshot: PaneSnapshot, now: Date, draggable: Bool, onSelectIndex: ((IndexSpec) -> Void)? = nil,
                onSelectFX: ((FXPairSpec) -> Void)? = nil) {
        self.snapshot = snapshot; self.now = now; self.draggable = draggable
        self.onSelectIndex = onSelectIndex; self.onSelectFX = onSelectFX
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: st.s(10)) {
            HStack(spacing: st.s(8)) {
                AppGlyph()
                Text("行情窗").font(.system(size: st.s(13), weight: .semibold))
                Text(Fmt.header(now)).font(.system(size: st.s(11))).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(height: st.s(20))
            .contentShape(Rectangle())
            .background(draggable ? AnyView(WindowDragArea()) : AnyView(Color.clear))

            HStack(alignment: .top, spacing: st.s(16)) {
                VStack(alignment: .leading, spacing: st.s(6)) {
                    // 和右边「汇率」那一行同高：左边写「指数」，图例放在右侧
                    HStack(spacing: st.s(4)) {
                        Text("指数").font(.system(size: st.s(12), weight: .semibold))
                        Spacer(minLength: 0)
                        if st.showSectionLabels && st.showStatus { IndexLegend() }
                    }
                    .frame(height: st.s(16))
                    IndexListView(board: snapshot.indices, specs: snapshot.settings.content.indices, now: now, upIsRed: snapshot.settings.upIsRed, onSelect: onSelectIndex)
                    GroupCard {
                        GoldRow(quote: snapshot.indices?.gold, now: now, upIsRed: snapshot.settings.upIsRed)
                    }
                }
                .frame(minWidth: RowMetrics.columnWidth(st), maxWidth: .infinity, alignment: .leading)
                FXTablesView(fx: snapshot.fx, content: snapshot.settings.content, upIsRed: snapshot.settings.upIsRed, onSelect: onSelectFX)
                    .frame(minWidth: st.s(232), maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(st.s(16))
    }
}

/// 按窗口大小自适应的面板（`PaneScale.choose`）：
/// - 窗口变小：先缩字号，缩到 0.75 倍还放不下，就换 `PaneStyle.tiers` 里更紧凑的一档（整块整块地收：汇率先收成一张表，再收分区标题和图例、走势线、状态列）。
/// - 选中的那一档在选中的倍数下宽高都放得下，所以不会有哪一块被切一半。窗口比内容大：整体放大，最多 1.8 倍；多出来的宽度让两列伸展（价格列变宽），多出来的高度留在底部。
/// `tierSizes` 是每一档在 1 倍时的大小（与 `PaneStyle.tiers` 一一对应），由外面量好传进来。
public struct AdaptivePanel: View {
    let snapshot: PaneSnapshot
    let now: Date
    let tierSizes: [CGSize]
    let onSelectIndex: ((IndexSpec) -> Void)?
    let onSelectFX: ((FXPairSpec) -> Void)?

    public init(snapshot: PaneSnapshot, now: Date, tierSizes: [CGSize], onSelectIndex: ((IndexSpec) -> Void)? = nil,
                onSelectFX: ((FXPairSpec) -> Void)? = nil) {
        self.snapshot = snapshot; self.now = now; self.tierSizes = tierSizes
        self.onSelectIndex = onSelectIndex; self.onSelectFX = onSelectFX
    }

    public var body: some View {
        GeometryReader { geo in
            let pick = PaneScale.choose(width: geo.size.width, height: geo.size.height,
                                        tiers: tierSizes.map { (width: $0.width, height: $0.height) })
            PanelView(snapshot: snapshot, now: now, draggable: false, onSelectIndex: onSelectIndex, onSelectFX: onSelectFX)
                .environment(\.paneStyle, PaneStyle.tiers[pick.tier].scaled(CGFloat(pick.scale)))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
    }

    /// 每一档在 1 倍时的大小（App 用它算最小、最大尺寸）
    @MainActor public static func idealSizes(snapshot: PaneSnapshot, now: Date) -> [CGSize] {
        PaneStyle.tiers.map { style in
            NSHostingView(rootView: PanelView(snapshot: snapshot, now: now, draggable: false).environment(\.paneStyle, style)).fittingSize
        }
    }
}

/// 按住拖动整个窗口（面板是无边框窗口，没有系统标题栏）
public struct WindowDragArea: NSViewRepresentable {
    public init() {}
    public func makeNSView(context: Context) -> NSView { DragView() }
    public func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
