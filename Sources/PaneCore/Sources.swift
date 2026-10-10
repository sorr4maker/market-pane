import Foundation

// MARK: Yahoo spark（一次批量拿多个品种的最新价、昨收、交易时段，以及当天每 5 分钟的走势）

public struct SparkQuote: Sendable, Equatable {
    public let symbol: String
    public let price: Double
    public let previousClose: Double?
    public let time: Date
    public let session: Session?
    /// 当天的走势（range=1d、interval=5m）
    public let points: [PricePoint]
    public init(symbol: String, price: Double, previousClose: Double?, time: Date, session: Session?, points: [PricePoint] = []) {
        self.symbol = symbol; self.price = price; self.previousClose = previousClose; self.time = time; self.session = session
        self.points = points
    }
}

public struct SparkMetadata: Sendable {
    public let regularMarketPrice: Double
    public let instrumentType: String?
    public let exchangeTimezoneName: String?
    public let shortName: String?
    public let longName: String?
}

public enum YahooSparkParser {
    private struct Root: Decodable { let spark: Spark }
    private struct Spark: Decodable { let result: [Item]? }
    private struct Item: Decodable { let symbol: String; let response: [Resp]? }
    private struct Resp: Decodable { let meta: Meta; let timestamp: [Double]?; let indicators: YahooChartParser.Indicators? }
    private struct Meta: Decodable {
        let regularMarketPrice: Double?
        let regularMarketTime: Double?
        let previousClose: Double?
        let chartPreviousClose: Double?
        let currentTradingPeriod: Periods?
        let instrumentType: String?
        let exchangeTimezoneName: String?
        let shortName: String?
        let longName: String?
    }
    private struct Periods: Decodable { let regular: Period? }
    private struct Period: Decodable { let start: Double; let end: Double }

    public static func url(symbols: [String]) -> URL {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: ".-")
        let list = symbols.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: ",")
        return URL(string: "https://query1.finance.yahoo.com/v7/finance/spark?symbols=\(list)&range=1d&interval=5m")!
    }

    /// 试抓只需要价格和标的信息，不要求有价格时间或当天走势。
    public static func parseMetadata(_ data: Data, symbol: String) throws -> SparkMetadata {
        let root = try JSONDecoder().decode(Root.self, from: data)
        guard let meta = root.spark.result?.first(where: { $0.symbol == symbol })?.response?.first?.meta,
              let price = meta.regularMarketPrice, price.isFinite, price > 0 else { throw ParseError.empty }
        return SparkMetadata(regularMarketPrice: price, instrumentType: meta.instrumentType,
                             exchangeTimezoneName: meta.exchangeTimezoneName, shortName: meta.shortName, longName: meta.longName)
    }

    public static func parse(_ data: Data) throws -> [String: SparkQuote] {
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw ParseError.malformed("Yahoo spark: \(error)") }
        var out: [String: SparkQuote] = [:]
        for item in root.spark.result ?? [] {
            guard let resp = item.response?.first else { continue }
            let m = resp.meta
            guard let p = m.regularMarketPrice, p.isFinite, p > 0,
                  let t = m.regularMarketTime else { continue }
            let session = m.currentTradingPeriod?.regular.map {
                Session(start: Date(timeIntervalSince1970: $0.start), end: Date(timeIntervalSince1970: $0.end))
            }
            let points = PricePoint.from(timestamps: resp.timestamp, closes: resp.indicators?.quote?.first?.close)
            out[item.symbol] = SparkQuote(symbol: item.symbol, price: p, previousClose: m.previousClose ?? m.chartPreviousClose,
                                          time: Date(timeIntervalSince1970: t), session: session, points: points)
        }
        guard !out.isEmpty else { throw ParseError.empty }
        return out
    }
}

// MARK: 新浪 A 股行情（上证指数）

public struct SinaQuote: Sendable, Equatable {
    public let code: String
    public let name: String
    public let open: Double
    public let previousClose: Double
    public let price: Double
    public let high: Double
    public let low: Double
    public let time: Date
    public init(code: String, name: String, open: Double, previousClose: Double, price: Double, high: Double, low: Double, time: Date) {
        self.code = code; self.name = name; self.open = open; self.previousClose = previousClose
        self.price = price; self.high = high; self.low = low; self.time = time
    }
}

public enum SinaParser {
    public static let headers = ["Referer": "https://finance.sina.com.cn"] // 没有 Referer 会 403
    public static func url(codes: [String]) -> URL {
        URL(string: "https://hq.sinajs.cn/list=\(codes.joined(separator: ","))")!
    }

    /// 新浪返回 GBK 编码的多行 `var hq_str_代码="字段,字段,…";` → [代码: 字段]
    static func lines(_ data: Data) throws -> [(code: String, fields: [String])] {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        guard let text = String(data: data, encoding: gbk) ?? String(data: data, encoding: .utf8) else {
            throw ParseError.malformed("新浪：无法解码")
        }
        var out: [(String, [String])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let codeStart = line.range(of: "hq_str_"), let eq = line.range(of: "=\""),
                  let endQuote = line.range(of: "\"", options: .backwards), endQuote.lowerBound > eq.upperBound else { continue }
            let code = String(line[codeStart.upperBound..<eq.lowerBound])
            out.append((code, line[eq.upperBound..<endQuote.lowerBound].split(separator: ",", omittingEmptySubsequences: false).map(String.init)))
        }
        return out
    }

    private static func beijing(_ date: String, _ time: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: "\(date) \(time)")
    }

    /// A 股 / 指数（sh000001）字段：0 名称, 1 今开, 2 昨收, 3 当前价, 4 最高, 5 最低, …, 30 日期, 31 时间（北京时间）
    public static func parseAShare(_ data: Data) throws -> [String: SinaQuote] {
        var out: [String: SinaQuote] = [:]
        for (code, fields) in try lines(data) where !code.hasPrefix("hf_") {
            guard fields.count >= 32,
                  let open = Double(fields[1]), let prev = Double(fields[2]), let price = Double(fields[3]),
                  let high = Double(fields[4]), let low = Double(fields[5]), price > 0,
                  let time = beijing(fields[30], fields[31]) else { continue }
            out[code] = SinaQuote(code: code, name: fields[0], open: open, previousClose: prev, price: price,
                                  high: high, low: low, time: time)
        }
        guard !out.isEmpty else { throw ParseError.empty }
        return out
    }

    /// 外盘期货 / 现货（hf_XAU 伦敦金）字段：0 现价, 1 昨收, 2 买价, 3 卖价, 4 最高, 5 最低, 6 时间(北京, 到分钟),
    /// 7 昨收, 8 开盘, 9–11 持仓/买卖量, 12 日期(北京), 13 名称。2026-10-08、10-09 两次实测核对过：第 7 列和第 1 列一致。
    public static func parseFutures(_ data: Data) throws -> [String: SinaQuote] {
        var out: [String: SinaQuote] = [:]
        for (code, fields) in try lines(data) where code.hasPrefix("hf_") {
            guard fields.count >= 14,
                  let price = Double(fields[0]), let high = Double(fields[4]), let low = Double(fields[5]),
                  let prev = Double(fields[7]), let open = Double(fields[8]), price > 0,
                  let time = beijing(fields[12], fields[6]) else { continue }
            out[code] = SinaQuote(code: code, name: fields[13], open: open, previousClose: prev, price: price,
                                  high: high, low: low, time: time)
        }
        guard !out.isEmpty else { throw ParseError.empty }
        return out
    }
}

// MARK: 日线（汇率用）

public struct DailyBar: Codable, Sendable, Equatable {
    public let date: String
    public let close: Double
    public init(date: String, close: Double) { self.date = date; self.close = close }
}

public enum YahooDailyParser {
    private struct Root: Decodable { let chart: Chart }
    private struct Chart: Decodable { let result: [Result]? }
    private struct Result: Decodable { let timestamp: [Double]?; let indicators: Indicators }
    private struct Indicators: Decodable { let quote: [Quote] }
    private struct Quote: Decodable { let close: [Double?] }

    public static func url(symbol: String) -> URL {
        let enc = symbol.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        return URL(string: "https://query1.finance.yahoo.com/v8/finance/chart/\(enc)?range=1mo&interval=1d")!
    }

    /// 按 `timeZone` 把时间戳换成日期（外汇日线按伦敦 0 点切日）。
    /// 末尾那行「当前价」和当天日线同一天，同日只留最后一行；收盘价为空的行丢掉。
    public static func parse(_ data: Data, timeZone: TimeZone) throws -> [DailyBar] {
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw ParseError.malformed("Yahoo chart: \(error)") }
        guard let r = root.chart.result?.first, let ts = r.timestamp, let closes = r.indicators.quote.first?.close
        else { throw ParseError.empty }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian); f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        var byDate: [String: Double] = [:]
        for (t, c) in zip(ts, closes) {
            guard let c, c.isFinite, c > 0 else { continue }
            byDate[f.string(from: Date(timeIntervalSince1970: t))] = c
        }
        guard !byDate.isEmpty else { throw ParseError.empty }
        return byDate.map { DailyBar(date: $0.key, close: $0.value) }.sorted { $0.date < $1.date }
    }
}

/// Frankfurter（欧洲央行参考价）区间接口，base=USD：`rates[日期][币种]` = 1 美元兑多少该货币。没有新台币。
public enum FrankfurterParser {
    private struct Root: Decodable { let rates: [String: [String: Double]] }

    public static func parse(_ data: Data) throws -> [String: [DailyBar]] {
        let root: Root
        do { root = try JSONDecoder().decode(Root.self, from: data) }
        catch { throw ParseError.malformed("Frankfurter: \(error)") }
        var out: [String: [DailyBar]] = [:]
        for (date, per) in root.rates {
            for (code, x) in per where x > 0 && x.isFinite { out[code, default: []].append(DailyBar(date: date, close: x)) }
        }
        guard !out.isEmpty else { throw ParseError.empty }
        return out.mapValues { $0.sorted { $0.date < $1.date } }
    }
}
