import Foundation

public enum Region: String, Codable, Sendable, CaseIterable { case asia = "亚太", europe = "欧洲", us = "美国" }

public struct IndexSpec: Sendable, Hashable {
    public let id: String
    public let name: String
    public let yahooSymbol: String
    /// 新浪代码；有的话和 Yahoo 比，取时间更新的那个（上证在新浪是实时的，Yahoo 晚 15 分钟）
    public let sinaCode: String?
    public let region: Region
    /// 交易所所在时区，用来显示「哪天的收盘」
    public let timeZoneID: String
    public var timeZone: TimeZone { TimeZone(identifier: timeZoneID)! }

    public static let all: [IndexSpec] = [
        .init(id: "SSE",  name: "上证指数",   yahooSymbol: "000001.SS", sinaCode: "sh000001", region: .asia,   timeZoneID: "Asia/Shanghai"),
        .init(id: "TWII", name: "台湾加权",   yahooSymbol: "^TWII",     sinaCode: nil,        region: .asia,   timeZoneID: "Asia/Taipei"),
        .init(id: "N225", name: "日经225",    yahooSymbol: "^N225",     sinaCode: nil,        region: .asia,   timeZoneID: "Asia/Tokyo"),
        .init(id: "KS11", name: "韩国综合",   yahooSymbol: "^KS11",     sinaCode: nil,        region: .asia,   timeZoneID: "Asia/Seoul"),
        .init(id: "FTSE", name: "富时100",    yahooSymbol: "^FTSE",     sinaCode: nil,        region: .europe, timeZoneID: "Europe/London"),
        .init(id: "DAX",  name: "DAX",        yahooSymbol: "^GDAXI",    sinaCode: nil,        region: .europe, timeZoneID: "Europe/Berlin"),
        .init(id: "CAC",  name: "CAC 40",     yahooSymbol: "^FCHI",     sinaCode: nil,        region: .europe, timeZoneID: "Europe/Paris"),
        .init(id: "NDX",  name: "纳斯达克100", yahooSymbol: "^NDX",      sinaCode: nil,        region: .us,     timeZoneID: "America/New_York"),
        .init(id: "SPX",  name: "标普500",    yahooSymbol: "^GSPC",     sinaCode: nil,        region: .us,     timeZoneID: "America/New_York"),
        .init(id: "DJI",  name: "道琼斯",     yahooSymbol: "^DJI",      sinaCode: nil,        region: .us,     timeZoneID: "America/New_York"),
        .init(id: "VIX",  name: "VIX",        yahooSymbol: "^VIX",      sinaCode: nil,        region: .us,     timeZoneID: "America/New_York"),
        .init(id: "VXN",  name: "VXN",        yahooSymbol: "^VXN",      sinaCode: nil,        region: .us,     timeZoneID: "America/New_York"),
    ]

    public static func spec(_ id: String) -> IndexSpec? { all.first { $0.id == id } }
}

/// 常规交易时段（Yahoo 的 currentTradingPeriod.regular）
public struct Session: Codable, Sendable, Equatable {
    public let start: Date
    public let end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
    public func contains(_ d: Date) -> Bool { d >= start && d < end }
}

public struct IndexQuote: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// 交易中是最新价（可能有延迟），收盘后就是收盘价
    public let price: Double
    public let previousClose: Double?
    /// 这个价格对应的时间
    public let time: Date
    public let session: Session?
    public let source: QuoteSource
    /// 当天的走势，画迷你走势线用。可选：旧版本存下的快照里没有这个字段，照样能读。
    public let intraday: [PricePoint]?

    public init(id: String, price: Double, previousClose: Double?, time: Date, session: Session?, source: QuoteSource,
                intraday: [PricePoint]? = nil) {
        self.id = id; self.price = price; self.previousClose = previousClose
        self.time = time; self.session = session; self.source = source; self.intraday = intraday
    }

    public var change: Double? { previousClose.map { price - $0 } }
    public var changePercent: Double? {
        guard let p = previousClose, p != 0 else { return nil }
        return (price - p) / p * 100
    }

    /// 在常规时段内就是交易中；拿不到时段时，价格 3 分钟内更新过才算交易中。
    public func isTrading(at now: Date) -> Bool {
        if let session { return session.contains(now) }
        return now.timeIntervalSince(time) < 180
    }
}

/// 伦敦金现：新浪现货（hf_XAU），美元/盎司。不能点开看 K 线（Yahoo 没有现货金，只有期货）。
public enum Gold {
    public static let id = "XAU"
    public static let name = "伦敦金现"
    public static let sinaCode = "hf_XAU"
    /// 收盘日按纽约算（现货金的交易日在纽约 17:00 结束）
    public static let timeZone = TimeZone(identifier: "America/New_York")!

    /// 现货金交易时间：纽约周日 18:00 到周五 17:00，每天 17:00–18:00 休息一小时。
    /// 返回包含 `time` 的那一段（纽约前一天 18:00 到当天 17:00）；落在休息时间或周末就返回 nil。
    public static func session(containing time: Date) -> Session? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = timeZone
        guard let today18 = cal.date(bySettingHour: 18, minute: 0, second: 0, of: time) else { return nil }
        let start = time >= today18 ? today18 : cal.date(byAdding: .day, value: -1, to: today18)!
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: start),
              let end = cal.date(bySettingHour: 17, minute: 0, second: 0, of: nextDay) else { return nil }
        let weekday = cal.component(.weekday, from: start)   // 1 = 周日 … 5 = 周四；周五、周六 18:00 不开
        guard (1...5).contains(weekday), time < end else { return nil }
        return Session(start: start, end: end)
    }

    public static func quote(from sina: SinaQuote) -> IndexQuote {
        IndexQuote(id: id, price: sina.price, previousClose: sina.previousClose, time: sina.time,
                   session: session(containing: sina.time), source: .sina)
    }
}

public struct IndexBoard: Codable, Sendable, Equatable {
    public let quotes: [IndexQuote]
    public let fetchedAt: Date
    /// 伦敦金现。可选：旧版本存的快照里没有，照样能读。
    public let gold: IndexQuote?
    public init(quotes: [IndexQuote], fetchedAt: Date, gold: IndexQuote? = nil) {
        self.quotes = quotes; self.fetchedAt = fetchedAt; self.gold = gold
    }

    public func quote(_ id: String) -> IndexQuote? { quotes.first { $0.id == id } }
    /// 金价几乎全天都在交易，算进来后工作日基本一直按每分钟刷新（金价要实时）
    public func anyTrading(at now: Date) -> Bool {
        quotes.contains { $0.isTrading(at: now) } || gold?.isTrading(at: now) == true
    }

    /// 这次没抓到、或抓到的比旧的还旧，就沿用旧的，一次网络失败不会清空面板。顺序固定为 IndexSpec.all。
    public func merging(previous: IndexBoard?) -> IndexBoard {
        guard let previous else { return self }
        var merged: [IndexQuote] = []
        for spec in IndexSpec.all {
            let new = quote(spec.id), old = previous.quote(spec.id)
            if let new, let old { merged.append(new.time >= old.time ? new : old) }
            else if let q = new ?? old { merged.append(q) }
        }
        let g: IndexQuote? = {
            guard let new = gold else { return previous.gold }
            guard let old = previous.gold else { return new }
            return new.time >= old.time ? new : old
        }()
        return IndexBoard(quotes: merged, fetchedAt: fetchedAt, gold: g)
    }
}
