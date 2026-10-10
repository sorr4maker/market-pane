import SwiftUI
import PaneCore

public struct IndexListView: View {
    let board: IndexBoard?
    /// 面板上显示的指数（用户选的，顺序就是各地区卡片里的顺序）
    let specs: [IndexSpec]
    let now: Date
    let upIsRed: Bool
    let onSelect: ((IndexSpec) -> Void)?
    @Environment(\.paneStyle) private var st
    public init(board: IndexBoard?, specs: [IndexSpec] = IndexSpec.all, now: Date, upIsRed: Bool, onSelect: ((IndexSpec) -> Void)? = nil) {
        self.board = board; self.specs = specs; self.now = now; self.upIsRed = upIsRed; self.onSelect = onSelect
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: st.s(6)) {
            ForEach(Region.allCases, id: \.self) { region in
                let inRegion = specs.filter { $0.region == region }
                // 这个地区一个指数都没选就不画这张卡片
                if !inRegion.isEmpty {
                    GroupCard(title: st.showSectionLabels ? region.rawValue : nil) {
                        ForEach(inRegion, id: \.id) { spec in
                            IndexRow(spec: spec, quote: board?.quote(spec.id), now: now, upIsRed: upIsRed,
                                     onSelect: onSelect.map { f in { f(spec) } })
                        }
                    }
                }
            }
        }
    }
}

/// 指数行和金价行共用的列宽（乘以缩放比例）。走势线、状态列按排版档位显示。
enum RowMetrics {
    static let name: CGFloat = 74, spark: CGFloat = 46, pct: CGFloat = 64, status: CGFloat = 50, spacing: CGFloat = 6, height: CGFloat = 18
    /// 左列宽度（含卡片左右各 10 的内边距）：完整 362；去掉走势线少 52；再去掉状态列少 56
    static func columnWidth(_ st: PaneStyle) -> CGFloat {
        var w: CGFloat = 362
        if !st.showSparkline { w -= spark + spacing }
        if !st.showStatus { w -= status + spacing }
        return st.s(w)
    }
}

/// 一行指数：名称、价格、当天迷你走势线、涨跌幅、状态。整行可点，点开看分时和日K/周K/月K。
struct IndexRow: View {
    let spec: IndexSpec
    let quote: IndexQuote?
    let now: Date
    let upIsRed: Bool
    var onSelect: (() -> Void)? = nil
    @State private var hovering = false
    @Environment(\.paneStyle) private var st

    var body: some View {
        HStack(spacing: st.s(RowMetrics.spacing)) {
            Text(spec.name).font(.system(size: st.s(12))).lineLimit(1).frame(width: st.s(RowMetrics.name), alignment: .leading)
            Text(Fmt.price(quote?.price)).font(.system(size: st.s(12), weight: .medium).monospacedDigit())
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            if st.showSparkline {
                Sparkline(points: quote?.intraday ?? [], session: quote?.session, baseline: quote?.previousClose,
                          color: Palette.change(quote?.changePercent, upIsRed: upIsRed))
                    .frame(width: st.s(RowMetrics.spark), height: st.s(13))
            }
            ChangePill(value: quote?.changePercent, upIsRed: upIsRed, width: RowMetrics.pct)
            if st.showStatus {
                StatusTag(quote: quote, timeZone: spec.timeZone, now: now).frame(width: st.s(RowMetrics.status), alignment: .leading)
            }
        }
        .frame(height: st.s(RowMetrics.height))
        .background(
            RoundedRectangle(cornerRadius: st.s(6), style: .continuous).fill(Color.primary.opacity(hovering && onSelect != nil ? 0.08 : 0))
                .padding(.horizontal, -st.s(5))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityHint(onSelect == nil ? "" : "查看走势")
    }
}

/// 伦敦金现一行：列宽和指数行一样（走势线那格留空，新浪现货没有分时序列），不能点开。
struct GoldRow: View {
    let quote: IndexQuote?
    let now: Date
    let upIsRed: Bool
    @Environment(\.paneStyle) private var st

    var body: some View {
        HStack(spacing: st.s(RowMetrics.spacing)) {
            HStack(spacing: st.s(5)) {
                Circle().fill(Palette.gold).frame(width: st.s(7), height: st.s(7))
                Text(Gold.name).font(.system(size: st.s(12))).lineLimit(1)
            }
            .frame(width: st.s(RowMetrics.name), alignment: .leading)
            Text(Fmt.price(quote?.price)).font(.system(size: st.s(12), weight: .medium).monospacedDigit())
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            if st.showSparkline { Color.clear.frame(width: st.s(RowMetrics.spark), height: st.s(13)) }
            ChangePill(value: quote?.changePercent, upIsRed: upIsRed, width: RowMetrics.pct)
            if st.showStatus {
                StatusTag(quote: quote, timeZone: Gold.timeZone, now: now).frame(width: st.s(RowMetrics.status), alignment: .leading)
            }
        }
        .frame(height: st.s(RowMetrics.height))
        .accessibilityElement(children: .combine)
    }
}

/// ● 蓝点 + 时间 = 交易中（时间是这个价格的时间，能看出延迟）；○ + 日期 = 已收盘（交易所当地的收盘日）
struct StatusTag: View {
    let quote: IndexQuote?
    let timeZone: TimeZone
    let now: Date
    @Environment(\.paneStyle) private var st
    var body: some View {
        if let q = quote {
            let live = q.isTrading(at: now)
            HStack(spacing: st.s(4)) {
                Circle().fill(live ? Palette.live : Color.clear)
                    .overlay(Circle().stroke(live ? Palette.live : Color.secondary.opacity(0.6), lineWidth: 1))
                    .frame(width: st.s(6), height: st.s(6))
                Text(live ? Fmt.clock(q.time) : Fmt.day(q.time, in: timeZone))
                    .font(.system(size: st.s(10)).monospacedDigit()).foregroundStyle(.secondary)
            }
        } else {
            Text("—").font(.system(size: st.s(10))).foregroundStyle(.secondary)
        }
    }
}

public struct IndexLegend: View {
    @Environment(\.paneStyle) private var st
    public init() {}
    public var body: some View {
        HStack(spacing: st.s(10)) {
            HStack(spacing: st.s(4)) { Circle().fill(Palette.live).frame(width: st.s(6), height: st.s(6)); Text("交易中 · 价格时间") }
            HStack(spacing: st.s(4)) { Circle().stroke(Color.secondary.opacity(0.6), lineWidth: 1).frame(width: st.s(6), height: st.s(6)); Text("已收盘 · 收盘日") }
        }
        .font(.system(size: st.s(9))).foregroundStyle(.secondary)
    }
}
