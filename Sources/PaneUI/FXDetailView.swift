import SwiftUI
import PaneCore

/// 点开汇率表里的一行：这个货币对的日K / 周K / 月K（汇率不做分时）。
public struct FXDetailView: View {
    let pair: FXPairSpec
    let upIsRed: Bool
    let load: @Sendable (ChartPeriod, Bool) async throws -> ChartSeries
    let onOpenExternal: (() -> Void)?
    let initialViewport: KLineViewport
    let initialHover: Int?

    @State private var period: ChartPeriod
    @State private var series: [ChartPeriod: ChartSeries]
    @State private var failed: Set<ChartPeriod> = []
    @State private var retryToken = 0

    public init(pair: FXPairSpec, upIsRed: Bool, initialPeriod: ChartPeriod = .daily, preloaded: [ChartPeriod: ChartSeries] = [:],
                initialViewport: KLineViewport = .init(), initialHover: Int? = nil,
                load: @escaping @Sendable (ChartPeriod, Bool) async throws -> ChartSeries, onOpenExternal: (() -> Void)? = nil) {
        self.pair = pair; self.upIsRed = upIsRed; self.load = load; self.onOpenExternal = onOpenExternal
        self.initialViewport = initialViewport; self.initialHover = initialHover
        _period = State(initialValue: ChartPeriod.fxPeriods.contains(initialPeriod) ? initialPeriod : .daily)
        _series = State(initialValue: preloaded)
    }

    private static let decimals = 4

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PeriodPicker(periods: ChartPeriod.fxPeriods, selection: $period)
            if let s = series[period], s.points.count >= 2 {
                KLineChart(series: s, upIsRed: upIsRed, decimals: Self.decimals, timeZone: FXCalendar.timeZone,
                           viewport: initialViewport, hover: initialHover)
                    .id(period)
            } else {
                ChartPlaceholder(failed: failed.contains(period)) { retryToken += 1 }
            }
            footer
        }
        .padding(18)
        .frame(width: 640)
        .task(id: "\(period.rawValue)#\(retryToken)") {
            do { series[period] = try await load(period, retryToken > 0); failed.remove(period) }
            catch { if series[period] == nil { failed.insert(period) } }
        }
    }

    /// 右上角：最新一根的收盘和比前一根的涨跌（汇率一直在交易，最新一根是今天还没走完的）
    private var header: some View {
        let pts = series[.daily]?.points ?? series[period]?.points ?? []
        let last = pts.last, prev = pts.dropLast().last
        let pct: Double? = { guard let l = last, let p = prev, p.price != 0 else { return nil }; return (l.price / p.price - 1) * 100 }()
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = FXCalendar.timeZone; f.dateFormat = "M/d"
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(pair.title).font(.system(size: 18, weight: .semibold))
                Text(pair.sourceNote).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(number(last?.price, decimals: Self.decimals)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                Text(Fmt.pct(pct)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Palette.change(pct, upIsRed: upIsRed))
                if let last { Text("\(f.string(from: last.time)) 最新").font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("数据：Yahoo Finance · 外汇按伦敦时间切日 · 面板汇率表是前一天的收盘，这里最新一根是今天还没走完的")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if let onOpenExternal {
                Button(action: onOpenExternal) { Text("在 Yahoo Finance 打开 ↗").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }
}
