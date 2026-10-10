import Foundation

public struct IndexService: Sendable {
    public let fetcher: HTTPFetching
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    /// Yahoo 批量请求拿 `specs` 里的指数，再用一个新浪请求拿 A 股指数实时价和伦敦金。
    public func fetch(asOf now: Date = Date(), specs: [IndexSpec] = IndexSpec.all) async -> IndexBoard {
        // A 股指数和伦敦金在同一个新浪请求里
        async let sinaData = try? fetcher.data(from: SinaParser.url(codes: specs.compactMap(\.sinaCode) + [Gold.sinaCode]),
                                               headers: SinaParser.headers)
        let symbols = specs.map(\.yahooSymbol)
        let yahoo = await withTaskGroup(of: [String: SparkQuote].self) { group in
            // 超过 20 个会被 Yahoo 拒绝；一批失败不影响其他批。
            for start in stride(from: 0, to: symbols.count, by: 20) {
                let batch = Array(symbols[start..<min(start + 20, symbols.count)])
                group.addTask {
                    guard let data = try? await fetcher.data(from: YahooSparkParser.url(symbols: batch)) else { return [:] }
                    return (try? YahooSparkParser.parse(data)) ?? [:]
                }
            }
            var out: [String: SparkQuote] = [:]
            for await batch in group { out.merge(batch) { first, _ in first } }
            return out
        }
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
    public func probe(symbol: String, name: String? = nil) async throws -> IndexSpec {
        let symbol = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !symbol.isEmpty else { throw ProbeError.notFound(symbol) }
        let data: Data
        do { data = try await fetcher.data(from: YahooSparkParser.url(symbols: [symbol])) }
        catch { throw ProbeError.network }
        guard let meta = try? YahooSparkParser.parseMetadata(data, symbol: symbol) else { throw ProbeError.notFound(symbol) }
        guard meta.instrumentType == "INDEX" else { throw ProbeError.notIndex(symbol, type: meta.instrumentType ?? "未知") }
        func nonempty(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let timeZoneID = meta.exchangeTimezoneName ?? "UTC"
        return IndexSpec(id: symbol, name: nonempty(name) ?? nonempty(meta.shortName) ?? nonempty(meta.longName) ?? symbol,
                         yahooSymbol: symbol, sinaCode: nil, region: Region.of(timeZoneID: timeZoneID), timeZoneID: timeZoneID)
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
