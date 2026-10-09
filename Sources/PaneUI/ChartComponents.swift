import SwiftUI
import Charts
import AppKit
import PaneCore

// MARK: - 截图开关

private struct ChartInteractionKey: EnvironmentKey { static let defaultValue = true }
public extension EnvironmentValues {
    /// K 线是否接鼠标/键盘。截图检查时关掉：ImageRenderer 画不出 AppKit 视图，会显示成一块禁止标志盖住图表
    var chartInteraction: Bool {
        get { self[ChartInteractionKey.self] }
        set { self[ChartInteractionKey.self] = newValue }
    }
}

// MARK: - 周期切换（纯 SwiftUI，截图时也能渲染出来）

struct PeriodPicker: View {
    let periods: [ChartPeriod]
    @Binding var selection: ChartPeriod
    var body: some View {
        HStack(spacing: 2) {
            ForEach(periods) { p in
                Button { selection = p } label: {
                    Text(p.label)
                        .font(.system(size: 12, weight: selection == p ? .semibold : .regular))
                        .foregroundStyle(selection == p ? Color.primary : Color.secondary)
                        .frame(width: 52, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(selection == p ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(p.label)
                .accessibilityAddTraits(selection == p ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

struct Stat<Value: View>: View {
    let label: String
    @ViewBuilder let value: () -> Value
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            value().font(.system(size: 13, weight: .medium).monospacedDigit())
        }
    }
}

func number(_ v: Double?, decimals: Int) -> String {
    guard let v else { return "—" }
    let n = NumberFormatter(); n.locale = Locale(identifier: "en_US"); n.numberStyle = .decimal
    n.minimumFractionDigits = decimals; n.maximumFractionDigits = decimals
    return n.string(from: v as NSNumber) ?? "—"
}

// MARK: - K 线（日K / 周K / 月K）

/// 同花顺那样的 K 线：拖动或触控板左右滑 → 平移；滚轮、触控板上下滑、捏合、↑↓ → 缩放；←→ → 逐根移动；
/// 鼠标移上去 → 竖线 + 上方信息栏显示那一根的开高低收。纵轴跟着屏幕里的 K 线自动调整。
public struct KLineChart: View {
    let series: ChartSeries
    let upIsRed: Bool
    let decimals: Int
    /// 显示日期用的时区：指数用交易所当地，汇率用伦敦（Yahoo 外汇日线按伦敦 0 点切）
    let timeZone: TimeZone
    @State private var viewport: KLineViewport
    @State private var hover: Int?
    @Environment(\.chartInteraction) private var interactive

    public init(series: ChartSeries, upIsRed: Bool, decimals: Int, timeZone: TimeZone,
                viewport: KLineViewport = .init(), hover: Int? = nil) {
        self.series = series; self.upIsRed = upIsRed; self.decimals = decimals; self.timeZone = timeZone
        _viewport = State(initialValue: viewport); _hover = State(initialValue: hover)
    }

    private var points: [PricePoint] { series.points }
    private var upColor: Color { upIsRed ? Palette.red : Palette.green }
    private var downColor: Color { upIsRed ? Palette.green : Palette.red }

    public var body: some View {
        if let range = viewport.visible(total: points.count) {
            VStack(alignment: .leading, spacing: 8) {
                infoBar(focus: hover.flatMap { range.contains($0) ? $0 : nil } ?? range.upperBound)
                chart(range).frame(height: 250)
                HStack {
                    Text("拖动或左右滑动平移 · 滚轮、捏合或 ↑↓ 缩放 · ←→ 逐根移动")
                    Spacer(minLength: 8)
                    Text("显示 \(range.count) 根 · 共 \(points.count) 根")
                }
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        } else {
            Text("没有数据").font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 250)
        }
    }

    // MARK: 信息栏（同花顺顶部那一行）

    private func infoBar(focus i: Int) -> some View {
        let p = points[i]
        let prev = i > 0 ? points[i - 1].price : nil
        let pct: Double? = prev.flatMap { $0 == 0 ? nil : (p.price - $0) / $0 * 100 }
        return HStack(spacing: 12) {
            Text(dateLabel(p.time)).foregroundStyle(.secondary)
            item("开", p.candleOpen); item("高", p.candleHigh); item("低", p.candleLow); item("收", p.price)
            Text(Fmt.pct(pct)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(Palette.change(pct, upIsRed: upIsRed))
            Spacer(minLength: 0)
        }
        .font(.system(size: 12).monospacedDigit())
        .lineLimit(1)
    }

    private func item(_ label: String, _ v: Double) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(number(v, decimals: decimals))
        }
    }

    // MARK: 图

    private func yDomain(_ r: ClosedRange<Int>) -> ClosedRange<Double> {
        let slice = points[r]
        let lo = slice.map(\.candleLow).min() ?? 0, hi = slice.map(\.candleHigh).max() ?? 1
        let pad = max((hi - lo) * 0.06, abs(hi) * 0.0005)
        return (lo - pad)...(hi + pad)
    }

    private func chart(_ r: ClosedRange<Int>) -> some View {
        let y = yDomain(r)
        let minBody = (y.upperBound - y.lowerBound) * 0.003   // 十字星至少留一条细线
        let ticks: [Double] = r.count > 1 ? (0..<5).map { (Double(r.lowerBound) + Double($0) / 4 * Double(r.count - 1)).rounded() } : [Double(r.lowerBound)]
        return Chart {
            ForEach(Array(r), id: \.self) { i in
                let p = points[i]
                let color = p.price >= p.candleOpen ? upColor : downColor
                let bodyLow = min(p.candleOpen, p.price)
                let bodyHigh = max(max(p.candleOpen, p.price), bodyLow + minBody)
                RuleMark(x: .value("序号", Double(i)), yStart: .value("最低", p.candleLow), yEnd: .value("最高", p.candleHigh))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1))
                RectangleMark(xStart: .value("开始", Double(i) - 0.36), xEnd: .value("结束", Double(i) + 0.36),
                              yStart: .value("实体下沿", bodyLow), yEnd: .value("实体上沿", bodyHigh))
                    .foregroundStyle(color)
            }
            if let h = hover, r.contains(h) {
                RuleMark(x: .value("序号", Double(h)))
                    .foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .chartXScale(domain: (Double(r.lowerBound) - 0.6)...(Double(r.upperBound) + 0.6))
        .chartYScale(domain: y)
        .chartXAxis {
            AxisMarks(values: ticks) { v in
                let i = Int((v.as(Double.self) ?? 0).rounded())
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(anchor: i <= r.lowerBound ? .topLeading : (i >= r.upperBound ? .topTrailing : .top)) {
                    Text(points.indices.contains(i) ? axisLabel(points[i].time) : "").font(.system(size: 10).monospacedDigit())
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 5)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel {
                    if let d = v.as(Double.self) {
                        Text(decimals > 2 ? number(d, decimals: decimals) : Fmt.axis(d)).font(.system(size: 10).monospacedDigit())
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
                if interactive { ChartInput(
                    candleWidth: plot.width / CGFloat(max(r.count, 1)),
                    onHover: { x in
                        guard let x, let v: Double = proxy.value(atX: x - plot.minX) else { hover = nil; return }
                        hover = min(max(Int(v.rounded()), r.lowerBound), r.upperBound)
                    },
                    onPan: { viewport.pan(by: $0, total: points.count) },
                    onZoom: { viewport.zoom(by: $0, total: points.count) }) }
            }
        }
    }

    private func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = timeZone; f.dateFormat = pattern; return f
    }

    private func dateLabel(_ d: Date) -> String {
        switch series.period {
        case .weekly: formatter("yyyy/M/d").string(from: d) + " 当周"
        case .monthly: formatter("yyyy年M月").string(from: d)
        default: formatter("yyyy/M/d EEE").string(from: d)
        }
    }

    private func axisLabel(_ d: Date) -> String {
        formatter(series.period == .daily ? "yy/M/d" : "yyyy/M").string(from: d)
    }
}

/// 接住 K 线上的鼠标、触控板和键盘操作（SwiftUI 在 macOS 14 上拿不到滚轮和捏合）。
/// 拖动和左右滑动累计到满一根 K 线的宽度才挪一根，所以手感和图上的位置对得上。
struct ChartInput: NSViewRepresentable {
    let candleWidth: CGFloat
    let onHover: (CGFloat?) -> Void
    /// 平移几根：正数往右（更新的），负数往左（更早的）
    let onPan: (Int) -> Void
    /// 缩放倍数：大于 1 放大（一屏根数变少）
    let onZoom: (Double) -> Void

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ v: InputView, context: Context) {
        v.candleWidth = max(candleWidth, 1); v.onHover = onHover; v.onPan = onPan; v.onZoom = onZoom
    }

    final class InputView: NSView {
        var candleWidth: CGFloat = 8
        var onHover: (CGFloat?) -> Void = { _ in }
        var onPan: (Int) -> Void = { _ in }
        var onZoom: (Double) -> Void = { _ in }
        private var lastDragX: CGFloat?
        private var panRemainder: CGFloat = 0

        override var acceptsFirstResponder: Bool { true }
        // 窗口设了「按背景拖动窗口」，这里要拦住，不然拖 K 线会把整个窗口拖走
        override var mouseDownCanMoveWindow: Bool { false }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self, let w = self.window else { return }
                w.makeFirstResponder(self)   // 打开窗口就能直接用方向键
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                           owner: self))
        }

        private func x(_ e: NSEvent) -> CGFloat { convert(e.locationInWindow, from: nil).x }

        override func mouseMoved(with e: NSEvent) { onHover(x(e)) }
        override func mouseExited(with e: NSEvent) { onHover(nil) }

        override func mouseDown(with e: NSEvent) {
            window?.makeFirstResponder(self)
            lastDragX = x(e); panRemainder = 0
        }
        override func mouseDragged(with e: NSEvent) {
            let now = x(e)
            if let last = lastDragX { pan(points: now - last) }
            lastDragX = now
            onHover(now)
        }
        override func mouseUp(with e: NSEvent) { lastDragX = nil }

        /// 往右拖 = 看更早的
        private func pan(points dx: CGFloat) {
            panRemainder += dx
            let steps = Int(panRemainder / candleWidth)
            guard steps != 0 else { return }
            panRemainder -= CGFloat(steps) * candleWidth
            onPan(-steps)
        }

        override func scrollWheel(with e: NSEvent) {
            let precise = e.hasPreciseScrollingDeltas   // 触控板 / 妙控鼠标：按点；普通滚轮：按行
            let dx = e.scrollingDeltaX * (precise ? 1 : 10), dy = e.scrollingDeltaY
            if abs(dx) > abs(dy) {
                pan(points: dx)
            } else if dy != 0 {
                onZoom(pow(precise ? 1.006 : 1.12, Double(dy)))
            }
        }

        override func magnify(with e: NSEvent) { onZoom(1 + Double(e.magnification)) }

        override func keyDown(with e: NSEvent) {
            switch e.keyCode {
            case 123: onPan(-1)                 // ←
            case 124: onPan(1)                  // →
            case 126: onZoom(1.25)              // ↑ 放大
            case 125: onZoom(0.8)               // ↓ 缩小
            case 53: window?.performClose(nil)  // Esc 关窗口
            default: super.keyDown(with: e)
            }
        }
    }
}

// MARK: - 分时

/// 当天分时走势：横轴是整个交易时段（盘中只画到当前），虚线是昨收；鼠标移上去看那一分钟的价格。
struct IntradayChart: View {
    let series: ChartSeries
    let session: Session?
    let upIsRed: Bool
    @Binding var hover: Int?

    private var points: [PricePoint] { series.points }

    var body: some View {
        let color = Palette.change(series.changePercent, upIsRed: upIsRed)
        let vals = points.map(\.price) + (series.baseline.map { [$0] } ?? [])
        let lo = vals.min() ?? 0, hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.08, abs(hi) * 0.0005)
        let y = (lo - pad)...(hi + pad)
        let x = SparkDomain.xRange(points: points, session: session) ?? (points.first!.time...points.last!.time)
        let gradient = LinearGradient(colors: [color.opacity(0.20), color.opacity(0)], startPoint: .top, endPoint: .bottom)
        Chart {
            if let b = series.baseline {
                RuleMark(y: .value("昨收", b)).foregroundStyle(Color.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                AreaMark(x: .value("时间", p.time), yStart: .value("底", y.lowerBound), yEnd: .value("价格", p.price))
                    .foregroundStyle(gradient)
                LineMark(x: .value("时间", p.time), y: .value("价格", p.price))
                    .foregroundStyle(color).lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .round))
            }
            if let h = hover, points.indices.contains(h) {
                let p = points[h]
                RuleMark(x: .value("时间", p.time)).foregroundStyle(Color.secondary.opacity(0.5))
                PointMark(x: .value("时间", p.time), y: .value("价格", p.price)).symbolSize(30).foregroundStyle(color)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { tip(p) }
            }
        }
        .chartXScale(domain: x)
        .chartYScale(domain: y)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.2))
                AxisValueLabel(centered: false) { if let d = v.as(Date.self) { Text(Fmt.clock(d)).font(.system(size: 10).monospacedDigit()) } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.secondary.opacity(0.25))
                AxisValueLabel { if let d = v.as(Double.self) { Text(Fmt.axis(d)).font(.system(size: 10).monospacedDigit()) } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        guard case .active(let loc) = phase, let plot = proxy.plotFrame,
                              let d: Date = proxy.value(atX: loc.x - geo[plot].origin.x) else { hover = nil; return }
                        hover = points.indices.min { abs(points[$0].time.timeIntervalSince(d)) < abs(points[$1].time.timeIntervalSince(d)) }
                    }
            }
        }
    }

    private func tip(_ p: PricePoint) -> some View {
        let pct = series.baseline.flatMap { $0 == 0 ? nil : (p.price - $0) / $0 * 100 }
        return VStack(alignment: .leading, spacing: 1) {
            Text(Fmt.price(p.price)).font(.system(size: 12, weight: .semibold).monospacedDigit())
            Text(Fmt.pct(pct)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Palette.change(pct, upIsRed: upIsRed))
            Text(Fmt.clock(p.time)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).shadow(color: .black.opacity(0.18), radius: 3, y: 1))
    }
}

// MARK: - 加载中 / 失败

struct ChartPlaceholder: View {
    let failed: Bool
    let retry: () -> Void
    var body: some View {
        Group {
            if failed {
                VStack(spacing: 8) {
                    Text("没抓到数据，可能是网络问题").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button(action: retry) { Text("重试").font(.system(size: 12, weight: .medium)) }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                }
            } else {
                Text("加载中…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 290)
    }
}
