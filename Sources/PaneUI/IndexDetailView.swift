import SwiftUI
import PaneCore

/// 点开一个指数：分时 / 日K / 周K / 月K。K 线可以拖动、缩放（见 KLineChart）。
/// 数据靠 `load` 按需抓（App 里是 ChartService）；截图检查时用 `preloaded` 直接塞进去。
public struct IndexDetailView: View {
    let spec: IndexSpec
    let quote: IndexQuote?
    let now: Date
    let upIsRed: Bool
    let load: @Sendable (ChartPeriod, Bool) async throws -> ChartSeries
    let onOpenExternal: (() -> Void)?
    let initialViewport: KLineViewport
    let initialKLineHover: Int?

    @State private var period: ChartPeriod
    @State private var series: [ChartPeriod: ChartSeries]
    @State private var failed: Set<ChartPeriod> = []
    @State private var retryToken = 0
    @State private var intradayHover: Int?

    public init(spec: IndexSpec, quote: IndexQuote?, now: Date, upIsRed: Bool, initialPeriod: ChartPeriod = .intraday,
                preloaded: [ChartPeriod: ChartSeries] = [:], initialViewport: KLineViewport = .init(), initialHover: Int? = nil,
                load: @escaping @Sendable (ChartPeriod, Bool) async throws -> ChartSeries,
                onOpenExternal: (() -> Void)? = nil) {
        self.spec = spec; self.quote = quote; self.now = now; self.upIsRed = upIsRed
        self.load = load; self.onOpenExternal = onOpenExternal
        self.initialViewport = initialViewport
        self.initialKLineHover = initialPeriod.isKLine ? initialHover : nil
        _period = State(initialValue: initialPeriod)
        _series = State(initialValue: preloaded)
        _intradayHover = State(initialValue: initialPeriod.isKLine ? nil : initialHover)
    }

    /// 末尾并上面板上的最新价（上证用新浪价时比 Yahoo 新；Yahoo 收盘后日K 常晚一阵才补当天那根，用当天分时补）
    private func shown(_ p: ChartPeriod) -> ChartSeries? {
        guard let s = series[p] else { return nil }
        guard let q = quote else { return s }
        return s.updatingLatest(price: q.price, time: q.time, today: series[.intraday], timeZone: spec.timeZone)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            PeriodPicker(periods: ChartPeriod.indexPeriods, selection: $period)
            if let s = shown(period), s.points.count >= 2 {
                if period.isKLine {
                    KLineChart(series: s, upIsRed: upIsRed, decimals: 2, timeZone: spec.timeZone,
                               viewport: initialViewport, hover: initialKLineHover)
                        .id(period)   // 换周期时视窗从最新一屏重新开始
                } else {
                    intradayStats(s)
                    IntradayChart(series: s, session: quote?.session, upIsRed: upIsRed, hover: $intradayHover).frame(height: 250)
                }
            } else {
                ChartPlaceholder(failed: failed.contains(period)) { retryToken += 1 }
            }
            footer
        }
        .padding(18)
        .frame(width: 640)
        .task(id: "\(period.rawValue)#\(retryToken)") { await loadLoop(period) }
        .onChange(of: period) { intradayHover = nil }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spec.name).font(.system(size: 18, weight: .semibold))
                Text("\(spec.cityName) · \(spec.yahooSymbol)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                Text(Fmt.price(quote?.price)).font(.system(size: 22, weight: .semibold).monospacedDigit())
                HStack(spacing: 8) {
                    Text(Fmt.signedPrice(quote?.change))
                    Text(Fmt.pct(quote?.changePercent))
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.change(quote?.changePercent, upIsRed: upIsRed))
                StatusTag(quote: quote, timeZone: spec.timeZone, now: now)
            }
        }
    }

    private func intradayStats(_ s: ChartSeries) -> some View {
        HStack(spacing: 28) {
            Stat(label: "当日涨跌") {
                HStack(spacing: 6) {
                    Text(Fmt.pct(s.changePercent))
                    Text(Fmt.signedPrice(s.change)).font(.system(size: 11).monospacedDigit()).opacity(0.85)
                }
                .foregroundStyle(Palette.change(s.changePercent, upIsRed: upIsRed))
            }
            Stat(label: "最高") { Text(Fmt.price(s.high)) }
            Stat(label: "最低") { Text(Fmt.price(s.low)) }
            Stat(label: "昨收") { Text(Fmt.price(s.baseline)) }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("数据：Yahoo Finance，多数指数延迟约 15 分钟 · 分时按本机时区，K 线日期按交易所当地")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer(minLength: 8)
            if let onOpenExternal {
                Button(action: onOpenExternal) { Text("在 Yahoo Finance 打开 ↗").font(.system(size: 11)) }
                    .buttonStyle(.plain).foregroundStyle(Color.accentColor)
            }
        }
    }

    /// 抓当前周期。K 线顺带抓当天分时，用来补今天那根的开高低。分时在交易中时每分钟重抓（缓存挡掉多余请求）。
    private func loadLoop(_ p: ChartPeriod) async {
        var force = retryToken > 0
        while !Task.isCancelled {
            do {
                series[p] = try await load(p, force)
                failed.remove(p)
            } catch {
                if series[p] == nil { failed.insert(p) }
            }
            if p.isKLine, let d = try? await load(.intraday, false) { series[.intraday] = d }
            force = false
            guard quote?.isTrading(at: Date()) == true else { return }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
