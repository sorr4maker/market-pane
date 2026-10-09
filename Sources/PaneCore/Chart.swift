import Foundation

/// 走势里的一个价格点；详情图里是一根 K 线。
/// `open/high/low` 只有 K 线用，迷你走势线和旧快照里都没有（可选字段，旧的 snapshot.json 照样能读）。
public struct PricePoint: Codable, Sendable, Equatable {
    public let time: Date
    /// 收盘价（迷你走势线只用这个）
    public let price: Double
    public let open: Double?
    public let high: Double?
    public let low: Double?
    public init(time: Date, price: Double, open: Double? = nil, high: Double? = nil, low: Double? = nil) {
        self.time = time; self.price = price; self.open = open; self.high = high; self.low = low
    }

    /// 画 K 线用：缺开盘就当开盘 = 收盘；最高最低一定包住开和收
    public var candleOpen: Double { open ?? price }
    public var candleHigh: Double { max(high ?? price, candleOpen, price) }
    public var candleLow: Double { min(low ?? price, candleOpen, price) }

    /// Yahoo 的 timestamp / close 两个数组 → 价格点；空值、非正数丢掉，按时间排序。
    static func from(timestamps: [Double]?, closes: [Double?]?) -> [PricePoint] {
        guard let timestamps, let closes else { return [] }
        return zip(timestamps, closes).compactMap { t, c in
            guard let c, c.isFinite, c > 0 else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: t), price: c)
        }.sorted { $0.time < $1.time }
    }

    /// 带开高低的版本：收盘为空的整根丢掉；开高低个别为空就留空（画的时候按收盘补）。
    static func candles(timestamps: [Double]?, opens: [Double?]?, highs: [Double?]?, lows: [Double?]?, closes: [Double?]?) -> [PricePoint] {
        guard let timestamps, let closes else { return [] }
        func at(_ a: [Double?]?, _ i: Int) -> Double? {
            guard let a, a.indices.contains(i), let v = a[i], v.isFinite, v > 0 else { return nil }
            return v
        }
        return timestamps.indices.compactMap { i in
            guard let c = at(closes, i) else { return nil }
            return PricePoint(time: Date(timeIntervalSince1970: timestamps[i]), price: c,
                              open: at(opens, i), high: at(highs, i), low: at(lows, i))
        }.sorted { $0.time < $1.time }
    }

    /// 把同一根 K 线里更晚的一行并进来：开不变，收取新的，高低取两者极值
    func absorbing(_ later: PricePoint) -> PricePoint {
        PricePoint(time: time, price: later.price, open: candleOpen,
                   high: max(candleHigh, later.candleHigh), low: min(candleLow, later.candleLow))
    }
}

/// 详情图：分时 + 日K / 周K / 月K（同花顺那样，K 线按每根代表的时长分）。指数四种都有，汇率只有三种 K 线。
public enum ChartPeriod: String, CaseIterable, Sendable, Identifiable {
    case intraday, daily, weekly, monthly
    public var id: String { rawValue }

    public static let indexPeriods: [ChartPeriod] = [.intraday, .daily, .weekly, .monthly]
    public static let fxPeriods: [ChartPeriod] = [.daily, .weekly, .monthly]

    public var label: String {
        switch self { case .intraday: "分时"; case .daily: "日K"; case .weekly: "周K"; case .monthly: "月K" }
    }
    public var isKLine: Bool { self != .intraday }

    /// 取多少历史：日K 10 年、周K 20 年、月K 30 年，往前翻有东西看。
    /// 不能用 range=max：Yahoo 会悄悄把粒度降成 3 个月（标普 1984 年至今只给 169 根季线）。
    var range: String {
        switch self { case .intraday: "1d"; case .daily: "10y"; case .weekly: "20y"; case .monthly: "30y" }
    }
    var interval: String {
        switch self { case .intraday: "1m"; case .daily: "1d"; case .weekly: "1wk"; case .monthly: "1mo" }
    }
    /// 抓到的数据缓存多久
    public var cacheTTL: TimeInterval {
        switch self { case .intraday: 60; case .daily: 600; case .weekly, .monthly: 3600 }
    }

    /// 一根 K 线在日历上的归属（时区用交易所当地）：日K 同一天、周K 同一周（周一开始）、月K 同一月。
    /// 分时按分钟。两个货币对拼交叉盘、并入最新价都靠它。
    public func candleKey(_ date: Date, timeZone: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone; cal.firstWeekday = 2; cal.minimumDaysInFirstWeek = 4
        switch self {
        case .intraday:
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return "\(c.year!)-\(c.month!)-\(c.day!) \(c.hour!):\(c.minute!)"
        case .daily:
            let c = cal.dateComponents([.year, .month, .day], from: date); return "\(c.year!)-\(c.month!)-\(c.day!)"
        case .weekly:
            let c = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date); return "\(c.yearForWeekOfYear!)W\(c.weekOfYear!)"
        case .monthly:
            let c = cal.dateComponents([.year, .month], from: date); return "\(c.year!)-\(c.month!)"
        }
    }

    public func sameCandle(_ a: Date, _ b: Date, timeZone: TimeZone) -> Bool {
        candleKey(a, timeZone: timeZone) == candleKey(b, timeZone: timeZone)
    }
}

public struct ChartSeries: Sendable, Equatable {
    public let period: ChartPeriod
    public let points: [PricePoint]
    /// 比较基准：日 = 昨收；其余 = 这段时间开始前的最后一个收盘价
    public let baseline: Double?
    public let fetchedAt: Date
    public init(period: ChartPeriod, points: [PricePoint], baseline: Double?, fetchedAt: Date) {
        self.period = period; self.points = points; self.baseline = baseline; self.fetchedAt = fetchedAt
    }

    public var change: Double? {
        guard let last = points.last, let baseline else { return nil }
        return last.price - baseline
    }
    public var changePercent: Double? {
        guard let change, let baseline, baseline != 0 else { return nil }
        return change / baseline * 100
    }
    /// 区间最高、最低：取每根 K 线的最高、最低（不只是收盘价）
    public var high: Double? { points.map(\.candleHigh).max() }
    public var low: Double? { points.map(\.candleLow).min() }

    /// 把面板上更新的价格接到日线末尾（上证用新浪价时比 Yahoo 新）：只接同一天、且更晚的点。
    public func appending(_ p: PricePoint, timeZone: TimeZone) -> ChartSeries {
        guard let last = points.last, p.time > last.time else { return self }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        guard cal.isDate(p.time, inSameDayAs: last.time) else { return self }
        return ChartSeries(period: period, points: points + [p], baseline: baseline, fetchedAt: fetchedAt)
    }
}

extension ChartSeries {
    /// 把面板上更新的价格并进末尾（上证用新浪价时比 Yahoo 新；Yahoo 收盘后日K 常过一阵才补上当天那根）：
    /// - 和最后一根同属一根（同一分钟 / 同一天 / 同一周 / 同一月）：更新收盘，高低跟着扩。
    /// - 更晚、不同根：另起一根。K 线用当天的分时 `today` 算出真实的开高低，没有分时就起一根开高低收相同的。
    /// - 分时只接同一天的。
    public func updatingLatest(price: Double, time: Date, today: ChartSeries?, timeZone: TimeZone) -> ChartSeries {
        guard let last = points.last, time > last.time else { return self }
        let latest = PricePoint(time: time, price: price, open: price, high: price, low: price)
        if period.sameCandle(last.time, time, timeZone: timeZone) {
            return ChartSeries(period: period, points: points.dropLast() + [last.absorbing(latest)], baseline: baseline, fetchedAt: fetchedAt)
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        if !period.isKLine && !cal.isDate(time, inSameDayAs: last.time) { return self }
        var candle = latest
        if period.isKLine, let todays = today?.points.filter({ cal.isDate($0.time, inSameDayAs: time) }), let first = todays.first {
            let highs = todays.map(\.candleHigh) + [price], lows = todays.map(\.candleLow) + [price]
            candle = PricePoint(time: first.time, price: price, open: first.candleOpen, high: highs.max()!, low: lows.min()!)
        }
        return ChartSeries(period: period, points: points + [candle], baseline: baseline, fetchedAt: fetchedAt)
    }

    /// 开盘或收盘本身就坏了的整根丢掉（不猜正确值是多少）：和前后两根的收盘都差 `maxJump` 以上。
    /// 实测 TWD=X 周线 2013-09-08 开盘 0.001、月线 2014-12 收盘 3.67（前后都是 30 左右）。
    public func droppingBadCandles(maxJump: Double) -> (series: ChartSeries, dropped: Int) {
        func far(_ v: Double, _ ref: Double?) -> Bool { ref.map { abs(v / $0 - 1) > maxJump } ?? true }
        var kept: [PricePoint] = []
        for (i, p) in points.enumerated() {
            let prev = i > 0 ? points[i - 1].price : nil, next = i + 1 < points.count ? points[i + 1].price : nil
            let bad = [p.price, p.candleOpen].contains { v in far(v, prev) && far(v, next) } && (prev != nil || next != nil)
            if !bad { kept.append(p) }
        }
        return (ChartSeries(period: period, points: kept, baseline: baseline, fetchedAt: fetchedAt), points.count - kept.count)
    }

    /// 削掉不可能的影线，返回削了几根。Yahoo 外汇数据的最高/最低价有不少坏值（收盘价没问题，和美联储官方汇率对得上）：
    /// TWD=X 月线最低 0.001、日线最低 27.7（当天开收都是 30.8）；CNY=X 周线最低 2.2；JPY=X 月线最高 635。
    /// 规则：影线超出实体的幅度，上限 = 这条序列影线中位数的 10 倍，且不低于 `minimumCap`；超过就削到上限。
    /// 只用在汇率上：指数数据是干净的，而且有真实的长影线（2020 年 3 月标普月线下影线约 15%）。
    public func clampingWicks(minimumCap: Double) -> (series: ChartSeries, clamped: Int) {
        guard !points.isEmpty else { return (self, 0) }
        let ext = points.flatMap { p -> [Double] in
            let top = max(p.candleOpen, p.price), bottom = min(p.candleOpen, p.price)
            return [p.candleHigh / top - 1, 1 - p.candleLow / bottom]
        }.sorted()
        let cap = max(ext[ext.count / 2] * 10, minimumCap)
        var clamped = 0
        let fixed = points.map { p -> PricePoint in
            let top = max(p.candleOpen, p.price), bottom = min(p.candleOpen, p.price)
            let high = min(p.candleHigh, top * (1 + cap)), low = max(p.candleLow, bottom * (1 - cap))
            guard high != p.candleHigh || low != p.candleLow else { return p }
            clamped += 1
            return PricePoint(time: p.time, price: p.price, open: p.candleOpen, high: high, low: low)
        }
        return (ChartSeries(period: period, points: fixed, baseline: baseline, fetchedAt: fetchedAt), clamped)
    }

    /// 每个价格乘以 k（汇率按 100 单位报价时用）
    public func scaled(_ k: Double) -> ChartSeries {
        guard k != 1 else { return self }
        return ChartSeries(period: period, points: points.map {
            PricePoint(time: $0.time, price: $0.price * k, open: $0.open.map { $0 * k }, high: $0.high.map { $0 * k }, low: $0.low.map { $0 * k })
        }, baseline: baseline.map { $0 * k }, fetchedAt: fetchedAt)
    }

    /// 取倒数（换报价方向）：开、收取倒数；最高变成 1/最低，最低变成 1/最高。是精确的。
    public func inverted() -> ChartSeries {
        ChartSeries(period: period, points: points.map {
            PricePoint(time: $0.time, price: 1 / $0.price, open: 1 / $0.candleOpen, high: 1 / $0.candleLow, low: 1 / $0.candleHigh)
        }, baseline: baseline.map { 1 / $0 }, fetchedAt: fetchedAt)
    }
}

/// K 线视窗：一屏显示几根、最右边是哪一根。拖动、滑动、滚轮、捏合、方向键都只改这个。
public struct KLineViewport: Equatable, Sendable {
    public static let minCount = 20, maxCount = 250
    /// 一屏几根
    public private(set) var count: Int
    /// 最右边那根的序号；nil = 贴着最新一根（有新数据时跟着走）
    public private(set) var right: Int?

    public init(count: Int = 60, right: Int? = nil) {
        self.count = min(max(count, Self.minCount), Self.maxCount); self.right = right
    }

    /// 在 total 根里，现在看得见的序号范围
    public func visible(total: Int) -> ClosedRange<Int>? {
        guard total > 0 else { return nil }
        let n = min(count, total)
        let r = min(max(right ?? total - 1, n - 1), total - 1)
        return (r - n + 1)...r
    }

    /// 平移：正数往右（更新的），负数往左（更早的）。到两头就停；回到最新一根就恢复「跟着最新」。
    public mutating func pan(by candles: Int, total: Int) {
        guard total > 0, candles != 0 else { return }
        let n = min(count, total)
        let r = min(max((right ?? total - 1) + candles, n - 1), total - 1)
        right = r >= total - 1 ? nil : r
    }

    /// 缩放：factor > 1 放大（一屏根数变少），以最右边那根为锚。
    public mutating func zoom(by factor: Double, total: Int) {
        guard factor > 0, factor.isFinite else { return }
        count = min(max(Int((Double(count) / factor).rounded()), Self.minCount), Self.maxCount)
        guard let r = right, total > 0 else { return }
        let clamped = min(max(r, min(count, total) - 1), total - 1)
        right = clamped >= total - 1 ? nil : clamped
    }
}

/// Yahoo chart 接口（按周期取一段走势）
public enum YahooChartParser {
    private struct Root: Decodable { let chart: Chart }
    private struct Chart: Decodable { let result: [Result]? }
    private struct Result: Decodable { let meta: Meta; let timestamp: [Double]?; let indicators: Indicators? }
    private struct Meta: Decodable {
        let previousClose: Double?; let chartPreviousClose: Double?; let exchangeTimezoneName: String?; let dataGranularity: String?
    }
    struct Indicators: Decodable { let quote: [Quote]? }
    struct Quote: Decodable { let open: [Double?]?; let high: [Double?]?; let low: [Double?]?; let close: [Double?]? }

    public static func url(symbol: String, period: ChartPeriod) -> URL {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: ".-")
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: allowed)!
        return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=\(period.range)&interval=\(period.interval)")!
    }

    public static func parse(_ data: Data, period: ChartPeriod, fetchedAt: Date) throws -> ChartSeries {
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw ParseError.malformed("Yahoo chart: \(error)") }
        guard let r = root.chart.result?.first else { throw ParseError.empty }
        // Yahoo 有时会悄悄降粒度（比如要月K 给季线）；对不上就当失败，宁可显示「重试」也不画错的 K 线
        if let g = r.meta.dataGranularity, g != period.interval {
            throw ParseError.malformed("Yahoo 返回的粒度是 \(g)，不是 \(period.interval)")
        }
        let q = r.indicators?.quote?.first
        let rows = PricePoint.candles(timestamps: r.timestamp, opens: q?.open, highs: q?.high, lows: q?.low, closes: q?.close)
        // Yahoo 常在末尾附加一行「当前价」，和最后一根 K 线同属一个时段；合并进去，免得多出一根重叠的
        let tz = r.meta.exchangeTimezoneName.flatMap(TimeZone.init(identifier:)) ?? TimeZone(identifier: "UTC")!
        var points: [PricePoint] = []
        for row in rows {
            if let last = points.last, period.sameCandle(last.time, row.time, timeZone: tz) {
                points[points.count - 1] = last.absorbing(row)
            } else {
                points.append(row)
            }
        }
        guard !points.isEmpty else { throw ParseError.empty }
        // 分时：昨收；K 线：这段历史开始前的收盘（界面上不用，留着备查）
        let baseline = period == .intraday ? (r.meta.previousClose ?? r.meta.chartPreviousClose) : r.meta.chartPreviousClose
        return ChartSeries(period: period, points: points, baseline: baseline, fetchedAt: fetchedAt)
    }
}

/// 点开指数或汇率后按需抓 K 线，带缓存；抓失败时有旧的就先用旧的。
public actor ChartService {
    private let fetcher: HTTPFetching
    private var cache: [String: ChartSeries] = [:]
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    public func series(symbol: String, period: ChartPeriod, now: Date = Date(), force: Bool = false) async throws -> ChartSeries {
        let key = "\(symbol)|\(period.rawValue)"
        if !force, let hit = cache[key], now.timeIntervalSince(hit.fetchedAt) < period.cacheTTL { return hit }
        do {
            let data = try await fetcher.data(from: YahooChartParser.url(symbol: symbol, period: period))
            let fresh = try YahooChartParser.parse(data, period: period, fetchedAt: now)
            cache[key] = fresh
            return fresh
        } catch {
            if let stale = cache[key] { return stale }
            throw error
        }
    }
}

public enum SparkDomain {
    /// 迷你走势线的横轴：价格点都落在交易时段里，就用整个时段（盘中只画到一半，看得出今天走了多少）；
    /// 否则（时段已经是下一个交易日的）用数据自己的首尾。
    public static func xRange(points: [PricePoint], session: Session?) -> ClosedRange<Date>? {
        guard let first = points.first?.time, let last = points.last?.time else { return nil }
        if let s = session, first >= s.start.addingTimeInterval(-300), last <= s.end.addingTimeInterval(300), s.end > s.start {
            return s.start...s.end
        }
        return first < last ? first...last : nil
    }
}

public extension IndexSpec {
    /// 交易所所在城市，用来说明详情图的时间是哪里的时间
    var cityName: String {
        switch timeZoneID {
        case "Asia/Shanghai": "北京"
        case "Asia/Taipei": "台北"
        case "Asia/Tokyo": "东京"
        case "Asia/Seoul": "首尔"
        case "Europe/London": "伦敦"
        case "Europe/Berlin": "法兰克福"
        case "Europe/Paris": "巴黎"
        case "America/New_York": "纽约"
        default: timeZoneID
        }
    }

    /// Yahoo Finance 上这个指数的页面
    var yahooPageURL: URL {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: ".-")
        return URL(string: "https://finance.yahoo.com/quote/\(yahooSymbol.addingPercentEncoding(withAllowedCharacters: allowed)!)/")!
    }
}
