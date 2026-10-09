import Foundation

public struct IndexService: Sendable {
    public let fetcher: HTTPFetching
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    /// 一个 Yahoo 批量请求拿全部 12 个指数，再用一个新浪请求拿上证实时价。
    public func fetch(asOf now: Date = Date()) async -> IndexBoard {
        async let sparkData = try? fetcher.data(from: YahooSparkParser.url(symbols: IndexSpec.all.map(\.yahooSymbol)))
        // 上证和伦敦金在同一个新浪请求里
        async let sinaData = try? fetcher.data(from: SinaParser.url(codes: IndexSpec.all.compactMap(\.sinaCode) + [Gold.sinaCode]),
                                               headers: SinaParser.headers)
        let yahoo = (await sparkData).flatMap { try? YahooSparkParser.parse($0) } ?? [:]
        let sinaRaw = await sinaData
        let sina = sinaRaw.flatMap { try? SinaParser.parseAShare($0) } ?? [:]
        let gold = sinaRaw.flatMap { try? SinaParser.parseFutures($0) }?[Gold.sinaCode].map(Gold.quote(from:))
        return IndexBoard(quotes: Self.combine(yahoo: yahoo, sina: sina), fetchedAt: now, gold: gold)
    }

    /// 同一个指数两个来源都有时，取价格时间更新的那个；交易时段一律用 Yahoo 的（新浪不给时段）。
    public static func combine(yahoo: [String: SparkQuote], sina: [String: SinaQuote]) -> [IndexQuote] {
        var out: [IndexQuote] = []
        for spec in IndexSpec.all {
            let y = yahoo[spec.yahooSymbol]
            let s = spec.sinaCode.flatMap { sina[$0] }
            let points = y?.points ?? []
            var best = y.map {
                IndexQuote(id: spec.id, price: $0.price, previousClose: $0.previousClose, time: $0.time,
                           session: $0.session, source: .yahoo, intraday: points.isEmpty ? nil : points)
            }
            if let s, best == nil || s.time > best!.time {
                // 新浪只有当前价、没有走势：沿用 Yahoo 的当天走势，同一天的话把新浪这个更新的价格接在末尾
                let series = ChartSeries(period: .intraday, points: points, baseline: nil, fetchedAt: s.time)
                    .appending(PricePoint(time: s.time, price: s.price), timeZone: spec.timeZone).points
                let sameDay = series.last?.time == s.time
                best = IndexQuote(id: spec.id, price: s.price, previousClose: s.previousClose, time: s.time,
                                  session: y?.session, source: .sina, intraday: sameDay ? series : nil)
            }
            if let best { out.append(best) }
        }
        return out
    }
}
