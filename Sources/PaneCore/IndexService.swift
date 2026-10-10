import Foundation

public struct IndexService: Sendable {
    public let fetcher: HTTPFetching
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    /// Yahoo 批量请求拿 `specs` 里的指数，再用一个新浪请求拿 A 股指数实时价和伦敦金。
    /// TODO(sol)：Yahoo spark 一次最多 20 个代码，超过要分批并发请求再合并。
    public func fetch(asOf now: Date = Date(), specs: [IndexSpec] = IndexSpec.all) async -> IndexBoard {
        async let sparkData = try? fetcher.data(from: YahooSparkParser.url(symbols: specs.map(\.yahooSymbol)))
        // A 股指数和伦敦金在同一个新浪请求里
        async let sinaData = try? fetcher.data(from: SinaParser.url(codes: specs.compactMap(\.sinaCode) + [Gold.sinaCode]),
                                               headers: SinaParser.headers)
        let yahoo = (await sparkData).flatMap { try? YahooSparkParser.parse($0) } ?? [:]
        let sinaRaw = await sinaData
        let sina = sinaRaw.flatMap { try? SinaParser.parseAShare($0) } ?? [:]
        let gold = sinaRaw.flatMap { try? SinaParser.parseFutures($0) }?[Gold.sinaCode].map(Gold.quote(from:))
        return IndexBoard(quotes: Self.combine(yahoo: yahoo, sina: sina, specs: specs), fetchedAt: now, gold: gold)
    }

    /// 同一个指数两个来源都有时，取价格时间更新的那个；交易时段一律用 Yahoo 的（新浪不给时段）。
    public static func combine(yahoo: [String: SparkQuote], sina: [String: SinaQuote], specs: [IndexSpec] = IndexSpec.all) -> [IndexQuote] {
        var out: [IndexQuote] = []
        for spec in specs {
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

    /// 自填代码时先试抓一次：抓得到、类型是指数（不是期货、外汇、个股）才返回。名字用 `name`，没填就用 Yahoo 的简称；
    /// 地区按交易所时区归组（Region.of）。id 用 Yahoo 代码本身。
    /// TODO(sol)：实现。失败时抛 ProbeError，错误文案是中文、能直接显示给用户。
    public func probe(symbol: String, name: String? = nil) async throws -> IndexSpec {
        throw ProbeError.notFound(symbol)
    }
}

public enum ProbeError: Error, LocalizedError, Equatable {
    /// Yahoo 没有这个代码，或者没有价格
    case notFound(String)
    /// 有这个代码，但不是指数（instrumentType 不是 INDEX，比如期货、外汇、股票）
    case notIndex(String, type: String)
    /// 网络不通
    case network

    public var errorDescription: String? {
        switch self {
        case .notFound(let s): "Yahoo 上找不到「\(s)」，或者它现在没有价格。指数代码一般以 ^ 开头，例如 ^HSI。"
        case .notIndex(let s, let type): "「\(s)」不是指数（Yahoo 标的类型是 \(type)），这里只能加指数。"
        case .network: "连不上 Yahoo，检查一下网络再试。"
        }
    }
}
