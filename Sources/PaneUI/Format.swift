import SwiftUI
import PaneCore

enum Fmt {
    private static func nf(_ digits: Int, signed: Bool = false) -> NumberFormatter {
        let n = NumberFormatter(); n.locale = Locale(identifier: "en_US"); n.numberStyle = .decimal
        n.minimumFractionDigits = digits; n.maximumFractionDigits = digits
        if signed { n.positivePrefix = "+"; n.negativePrefix = "-" }
        return n
    }
    private static let price2 = nf(2), fx4 = nf(4), pct2 = nf(2, signed: true), signed2 = nf(2, signed: true)

    static func price(_ v: Double?) -> String { v.flatMap { price2.string(from: $0 as NSNumber) } ?? "—" }
    /// 纵轴刻度：上千点的不要小数
    static func axis(_ v: Double) -> String { (abs(v) >= 1000 ? price0 : price2).string(from: v as NSNumber) ?? "" }
    private static let price0 = nf(0)
    /// 带正负号的点数，例如 +12.34
    static func signedPrice(_ v: Double?) -> String { v.flatMap { signed2.string(from: $0 as NSNumber) } ?? "—" }
    static func fx(_ v: Double?) -> String { v.flatMap { fx4.string(from: $0 as NSNumber) } ?? "—" }
    static func pct(_ v: Double?) -> String { v.flatMap { pct2.string(from: $0 as NSNumber) }.map { $0 + "%" } ?? "—" }

    /// 交易中：价格时间，按这台 Mac 的时区
    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
    /// 已收盘：收盘日期，按交易所当地时区（美股 05:00 北京时间收盘，算美东的前一天）
    static func day(_ d: Date, in tz: TimeZone) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = tz; f.dateFormat = "M/d"; return f.string(from: d)
    }
    static func fxDay(_ ymd: String) -> String {
        guard let d = FXCalendar.date(fromYMD: ymd) else { return ymd }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = FXCalendar.timeZone; f.dateFormat = "M/d EEE"
        return f.string(from: d)
    }
    static func header(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日 EEE HH:mm"; return f.string(from: d)
    }
}

enum Palette {
    static let red = Color(red: 0.91, green: 0.27, blue: 0.27)
    static let green = Color(red: 0.16, green: 0.68, blue: 0.38)
    static let live = Color(red: 0.20, green: 0.52, blue: 0.96)
    static let gold = Color(red: 0.89, green: 0.68, blue: 0.16)

    static func change(_ v: Double?, upIsRed: Bool) -> Color {
        guard let v, abs(v) >= 0.005 else { return .secondary }   // 显示成 ±0.00% 的就不上色
        return (v > 0) == upIsRed ? red : green
    }
}

/// 面板排版档位：窗口变小时先缩字号，再小就从完整往紧凑依次整块收起内容；`scale` 是字号、列宽、间距共同乘的倍数。
public struct PaneStyle: Equatable, Sendable {
    public var scale: CGFloat = 1
    /// 汇率只显示一张表（人民币 / 新台币 / 美元 切换）
    public var fxSingle = false
    public var showSparkline = true
    public var showStatus = true
    /// 「亚太 / 欧洲 / 美国 / 商品」分区标题和底部图例
    public var showSectionLabels = true

    public init(scale: CGFloat = 1, fxSingle: Bool = false, showSparkline: Bool = true, showStatus: Bool = true, showSectionLabels: Bool = true) {
        self.scale = scale; self.fxSingle = fxSingle; self.showSparkline = showSparkline
        self.showStatus = showStatus; self.showSectionLabels = showSectionLabels
    }

    /// 从完整到最紧凑。按用户的选择，先把汇率收成一张可切换的表；
    /// 之后高度不够只收高度方向的（分区标题和图例），宽度不够才收宽度方向的（走势线、状态列），
    /// 免得面板只是矮一点、宽度还够时也把走势线收掉。
    public static let tiers: [PaneStyle] = [
        PaneStyle(),
        PaneStyle(fxSingle: true),
        PaneStyle(fxSingle: true, showSectionLabels: false),
        PaneStyle(fxSingle: true, showSparkline: false),
        PaneStyle(fxSingle: true, showSparkline: false, showSectionLabels: false),
        PaneStyle(fxSingle: true, showSparkline: false, showStatus: false),
        PaneStyle(fxSingle: true, showSparkline: false, showStatus: false, showSectionLabels: false),
    ]

    public func scaled(_ k: CGFloat) -> PaneStyle { var s = self; s.scale = k; return s }
    /// 按比例换算尺寸（字号、列宽、间距）
    public func s(_ v: CGFloat) -> CGFloat { v * scale }
}

private struct PaneStyleKey: EnvironmentKey { static let defaultValue = PaneStyle() }
public extension EnvironmentValues {
    var paneStyle: PaneStyle {
        get { self[PaneStyleKey.self] }
        set { self[PaneStyleKey.self] = newValue }
    }
}

struct SectionLabel: View {
    let text: String
    @Environment(\.paneStyle) private var st
    var body: some View {
        Text(text).font(.system(size: st.s(10), weight: .semibold)).foregroundStyle(.secondary)
    }
}

/// 分组卡片：淡淡的底色 + 圆角，里面是一组行（亚太、欧洲、一张汇率表……）。`title`、`note` 都没有时不画标题行。
struct GroupCard<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.paneStyle) private var st

    var body: some View {
        VStack(alignment: .leading, spacing: st.s(1)) {
            if title != nil || note != nil {
                HStack(spacing: st.s(6)) {
                    if let title { SectionLabel(text: title) }
                    if let note { Text(note).font(.system(size: st.s(9))).foregroundStyle(.tertiary) }
                }
                .padding(.bottom, st.s(2))
            }
            content()
        }
        .padding(.horizontal, st.s(10)).padding(.vertical, st.s(7))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: st.s(11), style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// 涨跌幅：数字按涨跌上色，底下垫一块同色的淡底（持平的用灰色）
struct ChangePill: View {
    let value: Double?
    let upIsRed: Bool
    let width: CGFloat
    var fontSize: CGFloat = 11.5
    @Environment(\.paneStyle) private var st

    var body: some View {
        let c = Palette.change(value, upIsRed: upIsRed)
        Text(Fmt.pct(value))
            .font(.system(size: st.s(fontSize), weight: .semibold).monospacedDigit())
            .foregroundStyle(c)
            .lineLimit(1)
            .frame(width: st.s(width), height: st.s(16))
            .background(RoundedRectangle(cornerRadius: st.s(5), style: .continuous).fill(c.opacity(0.10)))
    }
}

/// 面板外沿：一圈很细的描边（上亮下暗），让毛玻璃的边缘清楚一点
public struct PanelBorder: View {
    public init() {}
    public var body: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                          lineWidth: 0.75)
            .allowsHitTesting(false)
    }
}

/// 标题栏的小图标：和 App 图标同一组蓝紫渐变
struct AppGlyph: View {
    @Environment(\.paneStyle) private var st
    var body: some View {
        RoundedRectangle(cornerRadius: st.s(5.5), style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.52, blue: 0.98), Color(red: 0.42, green: 0.30, blue: 0.86)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: st.s(19), height: st.s(19))
            .overlay {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: st.s(10), weight: .bold)).foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}
