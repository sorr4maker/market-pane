import SwiftUI
import PaneCore

/// 指数行里的当天迷你走势线：线按当天涨跌上色，下面一层同色渐变，虚线是昨收。
/// 横轴是整个交易时段，盘中只画到当前时刻，看得出今天走了多少。
struct Sparkline: View {
    let points: [PricePoint]
    let session: Session?
    let baseline: Double?
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2, let xr = SparkDomain.xRange(points: points, session: session) else { return }
            let prices = points.map(\.price) + (baseline.map { [$0] } ?? [])
            guard let lo = prices.min(), let hi = prices.max() else { return }
            let span = max(hi - lo, abs(hi) * 1e-6)
            let t0 = xr.lowerBound.timeIntervalSince1970
            let tw = max(xr.upperBound.timeIntervalSince(xr.lowerBound), 1)
            func y(_ v: Double) -> CGFloat { 1 + (1 - (v - lo) / span) * (size.height - 2) }
            func pt(_ p: PricePoint) -> CGPoint {
                CGPoint(x: (p.time.timeIntervalSince1970 - t0) / tw * size.width, y: y(p.price))
            }
            if let baseline {
                var base = Path()
                base.move(to: CGPoint(x: 0, y: y(baseline))); base.addLine(to: CGPoint(x: size.width, y: y(baseline)))
                ctx.stroke(base, with: .color(.primary.opacity(0.28)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
            }
            var line = Path()
            line.move(to: pt(points[0]))
            for p in points.dropFirst() { line.addLine(to: pt(p)) }
            var area = line
            area.addLine(to: CGPoint(x: pt(points[points.count - 1]).x, y: size.height))
            area.addLine(to: CGPoint(x: pt(points[0]).x, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.26), color.opacity(0)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)   // 数值本身在旁边的价格和涨跌幅里
    }
}
