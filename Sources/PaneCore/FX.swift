import Foundation

/// 外汇日线按伦敦时间切日（Yahoo 外汇日线的时间戳是伦敦 0 点）；周一到周五交易。
public enum FXCalendar {
    public static let timeZone = TimeZone(identifier: "Europe/London")!
    private static var calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = timeZone; return c }()
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func ymd(_ date: Date) -> String { formatter.string(from: date) }
    public static func date(fromYMD s: String) -> Date? { formatter.date(from: s) }
    public static func shift(_ ymd: String, days: Int) -> String {
        guard let d = date(fromYMD: ymd), let r = calendar.date(byAdding: .day, value: days, to: d) else { return ymd }
        return Self.ymd(r)
    }

    /// 伦敦日期严格早于今天的最近一个工作日 = 「前一天」已经完整收盘的那根日线。
    public static func lastCompletedDay(asOf now: Date) -> String {
        var day = calendar.startOfDay(for: now)
        for _ in 0..<7 {
            day = calendar.date(byAdding: .day, value: -1, to: day)!
            let wd = calendar.component(.weekday, from: day) // 1 = 周日, 7 = 周六
            if wd != 1 && wd != 7 { break }
        }
        return ymd(day)
    }
}

public struct Currency: Sendable, Hashable {
    public let code: String
    public let name: String
    /// Yahoo 美元货币对；美元自己是 nil
    public let yahooSymbol: String?
    /// true：报价是「1 美元 = x 该货币」（CNY=X）；false：报价是「1 该货币 = x 美元」（EURUSD=X）
    public let quotedPerUSD: Bool
    /// 大致的「1 美元 = ? 该货币」，只用来给汇率表选单位（100 日元、1 美元……），汇率变化几倍以内单位都不会变
    public let approxPerUSD: Double

    /// 「编辑内容」里能选的币种。前 6 个是用户最早要的：中、日、美、欧、台、港
    public static let all: [Currency] = [
        .init(code: "CNY", name: "人民币",   yahooSymbol: "CNY=X",    quotedPerUSD: true,  approxPerUSD: 7.1),
        .init(code: "JPY", name: "日元",     yahooSymbol: "JPY=X",    quotedPerUSD: true,  approxPerUSD: 150),
        .init(code: "USD", name: "美元",     yahooSymbol: nil,        quotedPerUSD: true,  approxPerUSD: 1),
        .init(code: "EUR", name: "欧元",     yahooSymbol: "EURUSD=X", quotedPerUSD: false, approxPerUSD: 0.92),
        .init(code: "TWD", name: "新台币",   yahooSymbol: "TWD=X",    quotedPerUSD: true,  approxPerUSD: 31.5),
        .init(code: "HKD", name: "港币",     yahooSymbol: "HKD=X",    quotedPerUSD: true,  approxPerUSD: 7.8),
        .init(code: "GBP", name: "英镑",     yahooSymbol: "GBPUSD=X", quotedPerUSD: false, approxPerUSD: 0.78),
        .init(code: "KRW", name: "韩元",     yahooSymbol: "KRW=X",    quotedPerUSD: true,  approxPerUSD: 1380),
        .init(code: "SGD", name: "新加坡元", yahooSymbol: "SGD=X",    quotedPerUSD: true,  approxPerUSD: 1.33),
        .init(code: "AUD", name: "澳元",     yahooSymbol: "AUDUSD=X", quotedPerUSD: false, approxPerUSD: 1.5),
        .init(code: "CAD", name: "加元",     yahooSymbol: "CAD=X",    quotedPerUSD: true,  approxPerUSD: 1.37),
        .init(code: "CHF", name: "瑞士法郎", yahooSymbol: "CHF=X",    quotedPerUSD: true,  approxPerUSD: 0.85),
        .init(code: "THB", name: "泰铢",     yahooSymbol: "THB=X",    quotedPerUSD: true,  approxPerUSD: 33),
        .init(code: "NZD", name: "新西兰元", yahooSymbol: "NZDUSD=X", quotedPerUSD: false, approxPerUSD: 1.65),
    ]
    public static func named(_ code: String) -> Currency {
        all.first { $0.code == code } ?? Currency(code: code, name: code, yahooSymbol: nil, quotedPerUSD: true, approxPerUSD: 1)
    }

    /// 汇率表里「? from = ? to」用几个单位：让数值至少是 1（100 日元 → 人民币、1 美元 → 人民币、1000 韩元 → 人民币）。
    /// 按大致汇率算，所以单位是固定的，不会今天 1 明天 100。默认三张表的单位和用户最早定的一致。
    public static func unit(from: String, to: String) -> Double {
        let v = named(to).approxPerUSD / named(from).approxPerUSD   // 1 from ≈ v to
        return [1.0, 100, 1000, 10000].first { v * $0 >= 1 } ?? 10000
    }
}

/// 只抓 5 个美元货币对，其余交叉汇率都由它们换算，三张表彼此一致。
public struct USDPair: Sendable {
    public let code: String
    public let yahooSymbol: String
    /// true：报价是「1 美元 = x 该货币」（CNY=X）；false：报价是「1 该货币 = x 美元」（EURUSD=X）
    public let quotedPerUSD: Bool
    public func usdPer(_ quote: Double) -> Double { quotedPerUSD ? 1 / quote : quote }

    /// 清单里全部非美元币种的货币对（实际抓哪些由 PaneContent.currencies 决定）
    public static let all: [USDPair] = Currency.all.compactMap { c in
        c.yahooSymbol.map { USDPair(code: c.code, yahooSymbol: $0, quotedPerUSD: c.quotedPerUSD) }
    }
    /// 欧洲央行参考价里没有新台币
    public var inECB: Bool { code != "TWD" }

    public static func pair(for code: String) -> USDPair? { all.first { $0.code == code } }
}

/// 汇率表里的一行 = 一个货币对：`unit` 个 from = ? to。点开看 K 线用。
public struct FXPairSpec: Sendable, Hashable, Identifiable {
    public let from: String
    public let to: String
    public let unit: Double
    public init(from: String, to: String, unit: Double = 1) { self.from = from; self.to = to; self.unit = unit }

    public var id: String { "\(from)>\(to)×\(Int(unit))" }
    /// 窗口标题，如「100日元 → 人民币」「1美元 → 日元」
    public var title: String { "\(Int(unit))\(Currency.named(from).name) → \(Currency.named(to).name)" }
    /// 要抓的 Yahoo 美元货币对（美元自己不用抓）
    public var legs: [USDPair] { [from, to].filter { $0 != "USD" }.compactMap(USDPair.pair(for:)) }
    /// 直接就是美元货币对：开高低收都是真实的；两边都不是美元时由两个美元货币对换算
    public var isDirect: Bool { from == "USD" || to == "USD" }
    public var sourceNote: String {
        let symbols = legs.map(\.yahooSymbol).joined(separator: " ÷ ")
        return isDirect
            ? "Yahoo \(symbols)\(unit == 1 ? "" : " ×\(Int(unit))")"
            : "由 Yahoo \(symbols) 换算：开、收精确；最高最低是上下限（可能比实际略宽）"
    }
}

/// 汇率 K 线：一律由美元货币对拼出来，不用 Yahoo 的直接交叉盘。
/// 实测（2026-10-09，对照美联储每日官方汇率）：TWDCNY=X 这类交叉盘十年里有 245 天偏差超过 1%（最大 9%，10/8 当天也差了 4%），
/// 而用 CNY=X、TWD=X 换算只有 58 天，且多是真实大波动（如 2025-05 台币急升）。换算出来的值也和面板汇率表完全一致。
public enum FXCross {
    /// 影线下限：日K 1%、周K 2%、月K 4%（实际上限按每条序列自己的正常影线长度放大 10 倍）
    static func minimumWickCap(_ p: ChartPeriod) -> Double {
        switch p { case .intraday, .daily: 0.01; case .weekly: 0.02; case .monthly: 0.04 }
    }

    /// 把某货币的美元货币对 K 线统一成「1 美元 = ? 该货币」，顺便清理 Yahoo 外汇数据：
    /// 先丢掉开收本身就坏了的整根，再削掉不可能的影线（顺序不能反，否则坏值会抬高影线中位数）
    public static func perUSD(_ s: ChartSeries, pair: USDPair) -> ChartSeries {
        let oriented = pair.quotedPerUSD ? s : s.inverted()
        return oriented.droppingBadCandles(maxJump: 0.3).series.clampingWicks(minimumCap: minimumWickCap(s.period)).series
    }

    /// 1 from = ? to（乘以 unit）。`perUSD`：各货币「1 美元 = ?」的 K 线（美元不用给）。按同一天/同一周/同一月配对。
    public static func series(_ pair: FXPairSpec, perUSD: [String: ChartSeries]) -> ChartSeries? {
        switch (pair.from, pair.to) {
        case ("USD", let to):
            return perUSD[to]?.scaled(pair.unit)
        case (let from, "USD"):
            return perUSD[from]?.inverted().scaled(pair.unit)
        default:
            guard let a = perUSD[pair.to], let b = perUSD[pair.from] else { return nil }
            let tz = FXCalendar.timeZone   // Yahoo 外汇日线按伦敦 0 点切
            var byKey: [String: PricePoint] = [:]
            for p in b.points { byKey[a.period.candleKey(p.time, timeZone: tz)] = p }
            let k = pair.unit
            let points = a.points.compactMap { pa -> PricePoint? in
                guard let pb = byKey[a.period.candleKey(pa.time, timeZone: tz)] else { return nil }
                // 1 from = (to/USD) ÷ (from/USD)。开、收是同一时刻的比值，精确；
                // 最高最低没法从两边的日高日低精确算出，取一定包住真实值的上下限
                return PricePoint(time: pa.time, price: pa.price / pb.price * k, open: pa.candleOpen / pb.candleOpen * k,
                                  high: pa.candleHigh / pb.candleLow * k, low: pa.candleLow / pb.candleHigh * k)
            }
            guard !points.isEmpty else { return nil }
            let baseline: Double? = { guard let x = a.baseline, let y = b.baseline, y != 0 else { return nil }; return x / y * k }()
            return ChartSeries(period: a.period, points: points, baseline: baseline, fetchedAt: min(a.fetchedAt, b.fetchedAt))
        }
    }

    /// 抓齐需要的美元货币对并拼成这个货币对的 K 线
    public static func load(_ pair: FXPairSpec, period: ChartPeriod, service: ChartService, force: Bool) async throws -> ChartSeries {
        var perUSD: [String: ChartSeries] = [:]
        for leg in pair.legs {
            perUSD[leg.code] = Self.perUSD(try await service.series(symbol: leg.yahooSymbol, period: period, force: force), pair: leg)
        }
        guard let s = series(pair, perUSD: perUSD) else { throw ParseError.empty }
        return s
    }
}

/// 一种货币在某个交易日的收盘：1 单位 = `usdPer` 美元
public struct FXPoint: Codable, Sendable, Equatable {
    public let code: String
    public let date: String
    public let usdPer: Double
    public let previousUsdPer: Double?
    public let source: QuoteSource
    public init(code: String, date: String, usdPer: Double, previousUsdPer: Double?, source: QuoteSource) {
        self.code = code; self.date = date; self.usdPer = usdPer; self.previousUsdPer = previousUsdPer; self.source = source
    }
}

public struct FXSnapshot: Codable, Sendable, Equatable {
    public let expectedDate: String
    public let points: [FXPoint]
    public let fetchedAt: Date
    public init(expectedDate: String, points: [FXPoint], fetchedAt: Date) {
        self.expectedDate = expectedDate; self.points = points; self.fetchedAt = fetchedAt
    }

    public func point(_ code: String) -> FXPoint? { points.first { $0.code == code } }
    func usdPer(_ code: String) -> Double? { code == "USD" ? 1 : point(code)?.usdPer }
    func previousUsdPer(_ code: String) -> Double? { code == "USD" ? 1 : point(code)?.previousUsdPer }

    /// 1 单位 a 等于多少 b
    public func value(of a: String, in b: String) -> Double? {
        guard let x = usdPer(a), let y = usdPer(b), y != 0 else { return nil }
        return x / y
    }
    public func previousValue(of a: String, in b: String) -> Double? {
        guard let x = previousUsdPer(a), let y = previousUsdPer(b), y != 0 else { return nil }
        return x / y
    }

    public var isStale: Bool { points.contains { $0.date < expectedDate } }
    /// `codes` 里（美元除外）没抓到的币种
    public func missing(in codes: [String]) -> [String] { codes.filter { $0 != "USD" && point($0) == nil } }
    public var displayDate: String? { points.map(\.date).max() }

    /// 按 `codes`（用户选的币种）合并，不在里面的旧数据丢掉
    public func merging(previous: FXSnapshot?, codes: [String] = PaneContent.standard.currencies) -> FXSnapshot {
        guard let previous else { return self }
        var merged: [FXPoint] = []
        for code in codes where code != "USD" {
            let new = point(code), old = previous.point(code)
            if let new, let old { merged.append(new.date >= old.date ? new : old) }
            else if let p = new ?? old { merged.append(p) }
        }
        return FXSnapshot(expectedDate: expectedDate, points: merged, fetchedAt: fetchedAt)
    }
}

// MARK: 三张表

public struct FXRowModel: Sendable, Equatable {
    public let label: String
    public let value: Double?
    public let changePercent: Double?
    /// 点开看 K 线用
    public let pair: FXPairSpec
}

public struct FXTableModel: Sendable, Equatable {
    public let title: String
    public let subtitle: String
    public let rows: [FXRowModel]
}

public enum FXTables {
    /// 人民币表、新台币表：「1 外币 = ? 本币」（日元、新台币、港币兑人民币按 100 单位）；
    /// 美元表：「1 美元 = ? 外币」（和 TradingView 的 USDCNY / USDJPY 一致，用户选的）。
    /// TODO(sol)：按 `content` 生成表：每个 baseTables 一张，行是 currencies 里除基准外的币种（按顺序），
    /// 单位用 Currency.unit(from:to:)；基准是美元时是「1 美元 = ? 外币」（单位固定 1）。标题用币种名，副标题沿用现在的写法。
    /// 默认内容（PaneContent.standard）生成的结果必须和下面旧的 build 完全一样。
    public static func build(_ s: FXSnapshot?, content: PaneContent) -> [FXTableModel] {
        build(s)
    }

    public static func build(_ s: FXSnapshot?) -> [FXTableModel] {
        func row(_ label: String, _ pair: FXPairSpec) -> FXRowModel {
            let v = s?.value(of: pair.from, in: pair.to), p = s?.previousValue(of: pair.from, in: pair.to)
            let pct: Double? = { guard let v, let p, p != 0 else { return nil }; return (v / p - 1) * 100 }()
            return FXRowModel(label: label, value: v.map { $0 * pair.unit }, changePercent: pct, pair: pair)
        }
        func intoBase(_ base: String, _ items: [(String, Double)]) -> [FXRowModel] {
            items.map { code, unit in
                row("\(Int(unit))\(Currency.named(code).name)", FXPairSpec(from: code, to: base, unit: unit))
            }
        }
        let cny = FXTableModel(title: "人民币", subtitle: "外币 → 人民币",
                               rows: intoBase("CNY", [("JPY", 100), ("USD", 1), ("EUR", 1), ("TWD", 100), ("HKD", 100)]))
        let twd = FXTableModel(title: "新台币", subtitle: "外币 → 新台币",
                               rows: intoBase("TWD", [("CNY", 1), ("JPY", 100), ("USD", 1), ("EUR", 1), ("HKD", 1)]))
        let usd = FXTableModel(title: "美元", subtitle: "1 美元 → 外币",
                               rows: ["CNY", "JPY", "EUR", "TWD", "HKD"].map {
                                   row(Currency.named($0).name, FXPairSpec(from: "USD", to: $0))
                               })
        return [cny, twd, usd]
    }
}

// MARK: 抓取

public struct FXService: Sendable {
    public let fetcher: HTTPFetching
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    static func frankfurterURL(codes: [String], expected: String) -> URL {
        URL(string: "https://api.frankfurter.dev/v1/\(FXCalendar.shift(expected, days: -20))..\(expected)?base=USD&symbols=\(codes.joined(separator: ","))")!
    }

    /// 每个货币对取「前一天」（伦敦日期 ≤ expected）的收盘和再前一天的收盘。
    /// Yahoo 拿不到或落后时，用欧洲央行参考价补（新台币没有备用源）。
    /// `codes`：要抓的币种（美元自动跳过）
    public func fetch(asOf now: Date = Date(), codes: [String] = PaneContent.standard.currencies) async -> FXSnapshot {
        let expected = FXCalendar.lastCompletedDay(asOf: now)
        let pairs = USDPair.all.filter { codes.contains($0.code) }
        var points = await withTaskGroup(of: FXPoint?.self) { group in
            for pair in pairs { group.addTask { await self.yahooPoint(pair, expected: expected) } }
            var out: [FXPoint] = []
            for await p in group { if let p { out.append(p) } }
            return out
        }
        let needFallback = pairs.filter { pair in
            pair.inECB && (points.first { $0.code == pair.code }.map { $0.date < expected } ?? true)
        }
        if !needFallback.isEmpty,
           let data = try? await fetcher.data(from: Self.frankfurterURL(codes: needFallback.map(\.code), expected: expected)),
           let series = try? FrankfurterParser.parse(data) {
            for pair in needFallback {
                let bars = (series[pair.code] ?? []).filter { $0.date <= expected }
                guard let p = Self.point(code: pair.code, bars: bars, usdPer: { 1 / $0 }, source: .ecb) else { continue }
                if let i = points.firstIndex(where: { $0.code == pair.code }) {
                    if p.date > points[i].date { points[i] = p }
                } else { points.append(p) }
            }
        }
        let order = pairs.map(\.code)
        points.sort { (order.firstIndex(of: $0.code) ?? 99) < (order.firstIndex(of: $1.code) ?? 99) }
        return FXSnapshot(expectedDate: expected, points: points, fetchedAt: now)
    }

    func yahooPoint(_ pair: USDPair, expected: String) async -> FXPoint? {
        guard let data = try? await fetcher.data(from: YahooDailyParser.url(symbol: pair.yahooSymbol)),
              let bars = try? YahooDailyParser.parse(data, timeZone: FXCalendar.timeZone) else { return nil }
        // 今天那根还没收盘（收盘价常为空），只要伦敦日期 ≤ 前一天的
        return Self.point(code: pair.code, bars: bars.filter { $0.date <= expected }, usdPer: pair.usdPer, source: .yahoo)
    }

    static func point(code: String, bars: [DailyBar], usdPer: (Double) -> Double, source: QuoteSource) -> FXPoint? {
        guard let last = bars.last else { return nil }
        return FXPoint(code: code, date: last.date, usdPer: usdPer(last.close),
                       previousUsdPer: bars.dropLast().last.map { usdPer($0.close) }, source: source)
    }
}
