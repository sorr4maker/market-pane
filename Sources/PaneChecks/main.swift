import Foundation
import PaneCore

// 没有用 XCTest：最简单的断言计数，失败退出码非 0。
var failures = 0, total = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    total += 1
    if ok { print("  ✓ \(name)") } else { failures += 1; print("  ✗ \(name)  \(detail())") }
}
func section(_ s: String) { print("\n\(s)") }
func near(_ a: Double?, _ b: Double, _ tol: Double = 1e-6) -> Bool { a.map { abs($0 - b) <= tol } ?? false }

let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Fixtures")
func fixture(_ n: String) -> Data { try! Data(contentsOf: fixtures.appendingPathComponent(n)) }
/// 新浪一次请求返回上证和伦敦金两行（两份样本抓取时间不同：上证 10/8 15:42，金价 10/9 00:56）
func sinaFixture() -> Data { fixture("sina_sh000001.txt") + Data("\n".utf8) + fixture("sina_hf_XAU.txt") }
func at(_ s: String, _ tz: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: tz)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f.date(from: s)!
}
final class Box<T>: @unchecked Sendable { var value: T? }
func run<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let box = Box<T>(), sem = DispatchSemaphore(value: 0)
    Task { box.value = await body(); sem.signal() }
    sem.wait(); return box.value!
}

// 样本抓取时刻：北京时间 2026-10-08 15:42:03
let sampleNow = ISO8601DateFormatter().date(from: String(data: fixture("spark_indices.fetched_at"), encoding: .utf8)!
    .trimmingCharacters(in: .whitespacesAndNewlines))!

// MARK: - Yahoo spark
section("Yahoo 批量接口解析（真实样本，北京时间 15:42 抓取）")
let spark = try! YahooSparkParser.parse(fixture("spark_indices.json"))
check("12 个指数全部解析出来", Set(spark.keys) == Set(IndexSpec.all.map(\.yahooSymbol)), "\(spark.keys.sorted())")
check("每个都有昨收和交易时段", spark.values.allSatisfy { $0.previousClose != nil && $0.session != nil })
check("纳指100 = 31160.076，昨收 31224.686", near(spark["^NDX"]?.price, 31160.076) && near(spark["^NDX"]?.previousClose, 31224.686))
check("垃圾数据抛错", (try? YahooSparkParser.parse(Data("{}".utf8))) == nil)
check("批量 URL 正确编码（^ → %5E）", YahooSparkParser.url(symbols: ["^NDX", "000001.SS"]).absoluteString.contains("symbols=%5ENDX,000001.SS"))

section("交易中 / 已收盘（按 Yahoo 给的交易时段判断）")
let combined0 = IndexService.combine(yahoo: spark, sina: [:])
let board0 = IndexBoard(quotes: combined0, fetchedAt: sampleNow)
let tradingNow = Set(board0.quotes.filter { $0.isTrading(at: sampleNow) }.map(\.id))
check("15:42：欧洲三个 + VIX（Cboe 夜盘）在交易，其余休市", tradingNow == ["FTSE", "DAX", "CAC", "VIX"], "\(tradingNow.sorted())")
check("周六中午：全部休市", !board0.anyTrading(at: at("2026-10-10 12:00:00", "Asia/Shanghai")))
check("欧洲价格时间 15:27，相对 15:42 正好延迟 15 分钟",
      abs(sampleNow.timeIntervalSince(board0.quote("FTSE")!.time) - 15 * 60) < 60)

// MARK: - 新浪
section("新浪上证（真实样本）")
let sina = try! SinaParser.parseAShare(fixture("sina_sh000001.txt"))
let sse = sina["sh000001"]!
check("名称 GBK 解码正确", sse.name == "上证指数", sse.name)
check("字段对位：今开 3838.9774 / 昨收 3842.1946 / 当前 3811.9043", near(sse.open, 3838.9774) && near(sse.previousClose, 3842.1946) && near(sse.price, 3811.9043))
check("当前价在最高最低之间", sse.low <= sse.price && sse.price <= sse.high)
check("时间 = 北京时间 2026-10-08 15:35:31", sse.time == at("2026-10-08 15:35:31", "Asia/Shanghai"))
check("空行情被跳过", (try? SinaParser.parseAShare(Data("var hq_str_sh000001=\"\";".utf8))) == nil)

section("合并两个来源（取更新的那个）")
let combined = IndexService.combine(yahoo: spark, sina: sina)
let sseQ = combined.first { $0.id == "SSE" }!
check("上证：新浪 15:35 比 Yahoo 15:00 新 → 用新浪", sseQ.source == .sina && near(sseQ.price, 3811.9043))
check("上证用新浪价格时仍沿用 Yahoo 的交易时段 → 15:42 判为休市", sseQ.session != nil && !sseQ.isTrading(at: sampleNow))
let oldSina = SinaQuote(code: "sh000001", name: "上证指数", open: 1, previousClose: 1, price: 1, high: 1, low: 1,
                        time: at("2026-10-08 10:00:00", "Asia/Shanghai"))
check("新浪更旧 → 用 Yahoo", IndexService.combine(yahoo: spark, sina: ["sh000001": oldSina]).first { $0.id == "SSE" }!.source == .yahoo)
check("其余 11 个都来自 Yahoo", combined.filter { $0.id != "SSE" }.allSatisfy { $0.source == .yahoo } && combined.count == 12)
let sinaOnly = IndexService.combine(yahoo: [:], sina: sina)
check("Yahoo 全挂：只剩上证（新浪），没有时段时按价格新旧判断", sinaOnly.map(\.id) == ["SSE"] && sinaOnly[0].session == nil
      && sinaOnly[0].isTrading(at: sse.time.addingTimeInterval(60)) && !sinaOnly[0].isTrading(at: sse.time.addingTimeInterval(600)))
check("顺序 = 亚太、欧洲、美国", combined.map(\.id) == IndexSpec.all.map(\.id))

// MARK: - 汇率
section("外汇日历（伦敦时间切日）")
check("样本时刻（伦敦 10/8 08:42）→ 前一天 = 10/7", FXCalendar.lastCompletedDay(asOf: sampleNow) == "2026-10-07")
check("周一凌晨 → 上周五", FXCalendar.lastCompletedDay(asOf: at("2026-10-12 00:30:00", "Europe/London")) == "2026-10-09")
check("周日 → 周五", FXCalendar.lastCompletedDay(asOf: at("2026-10-11 23:00:00", "Europe/London")) == "2026-10-09")

struct Mock: HTTPFetching {
    var yahooDown = false, sinaDown = false, ecbDown = false
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        let s = url.absoluteString
        if s.contains("spark") { if yahooDown { throw URLError(.timedOut) }; return fixture("spark_indices.json") }
        if s.contains("sinajs") { if sinaDown || headers["Referer"] == nil { throw URLError(.timedOut) }; return sinaFixture() }
        if s.contains("frankfurter") { if ecbDown { throw URLError(.timedOut) }; return fixture("ecb_usd.json") }
        if s.contains("chart/") {
            if yahooDown { throw URLError(.timedOut) }
            for (sym, file) in [("EURUSD%3DX", "fxd_EURUSD.json"), ("CNY%3DX", "fxd_CNY.json"), ("JPY%3DX", "fxd_JPY.json"),
                                ("TWD%3DX", "fxd_TWD.json"), ("HKD%3DX", "fxd_HKD.json")] where s.contains("chart/\(sym)") {
                return fixture(file)
            }
        }
        throw URLError(.cannotFindHost)
    }
}

section("汇率抓取（5 个美元货币对，真实样本）")
let fx = run { await FXService(fetcher: Mock()).fetch(asOf: sampleNow) }
check("5 个货币对都有，日期都是 10/7，来自 Yahoo", fx.points.count == 5 && fx.points.allSatisfy { $0.date == "2026-10-07" && $0.source == .yahoo }
      && !fx.isStale && fx.missing(in: PaneContent.standard.currencies).isEmpty, "\(fx.points.map { "\($0.code) \($0.date)" })")
check("美元兑人民币 10/7 = 6.7045", near(fx.value(of: "USD", in: "CNY"), 6.7045, 1e-5), "\(fx.value(of: "USD", in: "CNY")!)")
check("今天（10/8）那根没收盘的被排除", fx.points.allSatisfy { $0.date <= "2026-10-07" })

section("三张表的方向和单位")
let tables = FXTables.build(fx)
func cell(_ t: Int, _ label: String) -> FXRowModel { tables[t].rows.first { $0.label == label }! }
check("三张表：人民币 / 新台币 / 美元", tables.map(\.title) == ["人民币", "新台币", "美元"])
check("人民币表行 = 100日元、1美元、1欧元、100新台币、100港币", tables[0].rows.map(\.label) == ["100日元", "1美元", "1欧元", "100新台币", "100港币"])
check("新台币表行 = 1人民币、100日元、1美元、1欧元、1港币", tables[1].rows.map(\.label) == ["1人民币", "100日元", "1美元", "1欧元", "1港币"])
check("美元表行 = 人民币、日元、欧元、新台币、港币", tables[2].rows.map(\.label) == ["人民币", "日元", "欧元", "新台币", "港币"])
check("人民币表 1美元 = 6.7045", near(cell(0, "1美元").value, 6.7045, 1e-5))
check("新台币表 1美元 = USD/TWD 收盘 31.7769", near(cell(1, "1美元").value, 31.7769, 1e-4), "\(cell(1, "1美元").value!)")
check("美元表 日元 = USD/JPY 收盘 158.296", near(cell(2, "日元").value, 158.29601, 1e-3), "\(cell(2, "日元").value!)")
check("美元表 人民币 = 人民币表 1美元（同一个数）", near(cell(2, "人民币").value, cell(0, "1美元").value!, 1e-12))
check("100日元兑人民币 = 100 × 6.7045 / 158.296 ≈ 4.2354", near(cell(0, "100日元").value, 100 * 6.7045 / 158.29601, 1e-6))
check("来回换算一致：1人民币→新台币 × 100新台币→人民币 / 100 = 1",
      near(cell(1, "1人民币").value! * cell(0, "100新台币").value! / 100, 1, 1e-12))
check("每格都有涨跌幅", tables.allSatisfy { $0.rows.allSatisfy { $0.changePercent != nil } })

section("交叉校对：换算出来的人民币汇率 vs Yahoo 直接报的交叉盘（同为 10/7 收盘，应 < 0.5%）")
for (code, file) in [("JPY", "fx_JPYCNY.json"), ("USD", "fx_USDCNY.json"), ("EUR", "fx_EURCNY.json"), ("TWD", "fx_TWDCNY.json"), ("HKD", "fx_HKDCNY.json")] {
    let direct = try! YahooDailyParser.parse(fixture(file), timeZone: FXCalendar.timeZone).first { $0.date == "2026-10-07" }!.close
    let mine = fx.value(of: code, in: "CNY")!
    let diff = abs(mine - direct) / direct
    check("\(code)/CNY 换算 \(String(format: "%.5f", mine)) vs 直接报价 \(String(format: "%.5f", direct))，差 \(String(format: "%.3f", diff * 100))%", diff < 0.005)
}

section("备用源：欧洲央行（Yahoo 挂掉时）")
let fxECB = run { await FXService(fetcher: Mock(yahooDown: true)).fetch(asOf: sampleNow) }
check("补上人民币、日元、欧元、港币，日期 10/7", fxECB.points.map(\.code) == ["CNY", "JPY", "EUR", "HKD"] && fxECB.points.allSatisfy { $0.source == .ecb && $0.date == "2026-10-07" })
check("新台币缺失而不是编造", fxECB.missing(in: PaneContent.standard.currencies) == ["TWD"])
check("欧洲央行 1 美元 = 6.7046 人民币（取倒数正确）", near(fxECB.value(of: "USD", in: "CNY"), 6.7046, 1e-4), "\(fxECB.value(of: "USD", in: "CNY")!)")
let ecbTables = FXTables.build(fxECB)
check("缺新台币时：新台币表整张显示空，其他表里的新台币那行也空，其余正常",
      ecbTables[1].rows.allSatisfy { $0.value == nil } && ecbTables[0].rows[3].value == nil && ecbTables[2].rows[3].value == nil
      && ecbTables[0].rows[1].value != nil)
let fxNone = run { await FXService(fetcher: Mock(yahooDown: true, ecbDown: true)).fetch(asOf: sampleNow) }
check("两个源都挂：没有数据", fxNone.points.isEmpty && fxNone.missing(in: PaneContent.standard.currencies).count == 5)
check("没有数据时表格照样有 5 行，全部为空", FXTables.build(nil).allSatisfy { $0.rows.count == 5 && $0.rows.allSatisfy { $0.value == nil } })

section("汇率合并旧数据")
let partial = FXSnapshot(expectedDate: "2026-10-08", points: fx.points.filter { $0.code != "EUR" }.map {
    FXPoint(code: $0.code, date: "2026-10-08", usdPer: $0.usdPer, previousUsdPer: $0.usdPer, source: .yahoo) }, fetchedAt: sampleNow)
let mergedFX = partial.merging(previous: fx)
check("缺欧元：沿用旧的，其余用新的，并标记落后", mergedFX.point("EUR")?.date == "2026-10-07" && mergedFX.point("USD") == nil
      && mergedFX.point("CNY")?.date == "2026-10-08" && mergedFX.isStale)
check("全部失败：保留上一份", FXSnapshot(expectedDate: "2026-10-08", points: [], fetchedAt: sampleNow).merging(previous: fx).points == fx.points)

// MARK: - IndexService 端到端（假网络）
section("IndexService 抓取（假网络 + 真实样本）")
let b1 = run { await IndexService(fetcher: Mock()).fetch(asOf: sampleNow) }
check("12 个指数，上证来自新浪", b1.quotes.count == 12 && b1.quote("SSE")?.source == .sina)
let b2 = run { await IndexService(fetcher: Mock(sinaDown: true)).fetch(asOf: sampleNow) }
check("新浪挂了：上证回到 Yahoo", b2.quotes.count == 12 && b2.quote("SSE")?.source == .yahoo)
let b3 = run { await IndexService(fetcher: Mock(yahooDown: true)).fetch(asOf: sampleNow) }
check("Yahoo 挂了：只有上证", b3.quotes.map(\.id) == ["SSE"])
let b4 = b3.merging(previous: b1)
check("合并：Yahoo 挂了也保留上一次的 11 个指数", b4.quotes.count == 12 && b4.quote("NDX") == b1.quote("NDX"))
check("合并顺序固定", b4.quotes.map(\.id) == IndexSpec.all.map(\.id))

// MARK: - 刷新节奏
section("刷新节奏")
check("没有数据：马上抓", RefreshPolicy.indicesDue(nil, now: sampleNow))
check("有市场在交易、30 秒前刚抓：不抓", !RefreshPolicy.indicesDue(b1, now: sampleNow.addingTimeInterval(30)))
check("有市场在交易、1 分钟前抓的：抓", RefreshPolicy.indicesDue(b1, now: sampleNow.addingTimeInterval(60)))
let weekendBoard = IndexBoard(quotes: b1.quotes, fetchedAt: at("2026-10-10 12:00:00", "Asia/Shanghai"))
check("全部休市、2 分钟前抓的：不抓", !RefreshPolicy.indicesDue(weekendBoard, now: at("2026-10-10 12:02:00", "Asia/Shanghai")))
check("全部休市、5 分钟前抓的：抓", RefreshPolicy.indicesDue(weekendBoard, now: at("2026-10-10 12:05:01", "Asia/Shanghai")))
check("汇率完整且是前一天的：不抓", !RefreshPolicy.fxDue(fx, now: sampleNow.addingTimeInterval(3600)))
check("换日了（10/9 伦敦上午）且 15 分钟以上没抓：抓", RefreshPolicy.fxDue(fx, now: at("2026-10-09 09:00:00", "Europe/London")))
let fxJustTried = FXSnapshot(expectedDate: fxECB.expectedDate, points: fxECB.points, fetchedAt: sampleNow)
check("缺新台币、5 分钟前刚试过：先不抓", !RefreshPolicy.fxDue(fxJustTried, now: sampleNow.addingTimeInterval(300)))
check("缺新台币、16 分钟前试过：再试", RefreshPolicy.fxDue(fxJustTried, now: sampleNow.addingTimeInterval(960)))

// MARK: - 伦敦金现（新浪现货）
section("伦敦金现（新浪 hf_XAU，真实样本，北京时间 10/9 00:56 抓取）")
let goldSina = try! SinaParser.parseFutures(fixture("sina_hf_XAU.txt"))["hf_XAU"]!
check("名称 GBK 解码：伦敦金（现货黄金）", goldSina.name == "伦敦金（现货黄金）", goldSina.name)
check("字段对位：现价 4124.57 / 昨收 4110.68 / 开盘 4115.25 / 最高 4143.16 / 最低 4103.25",
      near(goldSina.price, 4124.57) && near(goldSina.previousClose, 4110.68) && near(goldSina.open, 4115.25)
      && near(goldSina.high, 4143.16) && near(goldSina.low, 4103.25))
check("时间 = 北京时间 2026-10-09 00:56:00", goldSina.time == at("2026-10-09 00:56:00", "Asia/Shanghai"))
check("A 股解析不会把金价那行当成上证", (try? SinaParser.parseAShare(fixture("sina_hf_XAU.txt"))) == nil)
check("两行一起返回时各取各的", Set((try! SinaParser.parseAShare(sinaFixture())).keys) == ["sh000001"]
      && Set((try! SinaParser.parseFutures(sinaFixture())).keys) == ["hf_XAU"])
let goldQ = Gold.quote(from: goldSina)
check("涨跌 = 现价 − 昨收 = +13.89（+0.34%）", near(goldQ.change, 13.89, 1e-6) && near(goldQ.changePercent, 13.89 / 4110.68 * 100, 1e-9))

section("伦敦金现的交易时间（纽约周日 18:00 到周五 17:00，每天 17:00–18:00 休息）")
check("北京 10/9 00:56 = 纽约 10/8 12:56 → 这一段是纽约 10/7 18:00 到 10/8 17:00",
      Gold.session(containing: goldQ.time) == Session(start: at("2026-10-07 18:00:00", "America/New_York"), end: at("2026-10-08 17:00:00", "America/New_York")))
check("北京 10/9 00:57：交易中", goldQ.isTrading(at: at("2026-10-09 00:57:00", "Asia/Shanghai")))
check("纽约 17:30（每日休息）：不在交易", !goldQ.isTrading(at: at("2026-10-08 17:30:00", "America/New_York")))
check("休息时间里的价格：没有时段", Gold.session(containing: at("2026-10-08 17:30:00", "America/New_York")) == nil)
let friday = Gold.session(containing: at("2026-10-09 16:59:00", "America/New_York"))
check("周五 16:59 的价格：时段到周五 17:00，周六不在时段里", friday?.end == at("2026-10-09 17:00:00", "America/New_York")
      && friday?.contains(at("2026-10-10 12:00:00", "America/New_York")) == false)
check("周六的时间：没有时段", Gold.session(containing: at("2026-10-10 12:00:00", "America/New_York")) == nil)
check("周日 18:30：时段从周日 18:00 开始", Gold.session(containing: at("2026-10-11 18:30:00", "America/New_York"))?.start
      == at("2026-10-11 18:00:00", "America/New_York"))
let dstEnd = Gold.session(containing: at("2026-11-01 19:00:00", "America/New_York"))
check("夏令时结束当天（11/1 周日）：18:00 开到周一 17:00，23 小时", dstEnd?.start == at("2026-11-01 18:00:00", "America/New_York")
      && dstEnd?.end == at("2026-11-02 17:00:00", "America/New_York") && dstEnd.map { $0.end.timeIntervalSince($0.start) } == 23 * 3600)

section("伦敦金现：抓取、合并、刷新")
check("同一个新浪请求顺带拿到金价", b1.gold?.price == 4124.57 && b1.gold?.source == .sina && b1.gold?.id == Gold.id)
check("新浪挂了：这次没有金价", b2.gold == nil)
check("合并：新浪挂了也保留上一次的金价", b2.merging(previous: b1).gold == b1.gold)
let olderGold = IndexBoard(quotes: [], fetchedAt: sampleNow, gold: IndexQuote(id: Gold.id, price: 1, previousClose: 1,
                           time: goldQ.time.addingTimeInterval(-600), session: nil, source: .sina))
check("合并：新抓到的金价比旧的还旧 → 留旧的", olderGold.merging(previous: b1).gold == b1.gold)
check("合并：旧的没有金价 → 用新的", b1.merging(previous: b2).gold == b1.gold)
let goldOnlyNow = at("2026-10-09 00:57:00", "Asia/Shanghai")
let goldOnly = IndexBoard(quotes: [], fetchedAt: goldOnlyNow, gold: goldQ)
check("只有金价在交易时也算交易中，按每分钟刷新", goldOnly.anyTrading(at: goldOnlyNow)
      && RefreshPolicy.indicesDue(goldOnly, now: goldOnlyNow.addingTimeInterval(60))
      && !RefreshPolicy.indicesDue(goldOnly, now: goldOnlyNow.addingTimeInterval(30)))

section("快照存取")
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("marketpane-\(UUID().uuidString)/snapshot.json")
let store = SnapshotStore(fileURL: tmp)
check("没有文件：nil", store.load() == nil)
let snap = PaneSnapshot(generatedAt: Date(timeIntervalSince1970: 1_791_000_000), indices: b1, fx: fx, settings: .init(upIsRed: false))
try! store.save(snap)
check("写入再读出一致", store.load() == snap)
try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

// MARK: - 当天走势（迷你走势线）
section("当天走势（spark 响应里每 5 分钟一个价格）")
check("12 个指数都带走势", spark.values.allSatisfy { !$0.points.isEmpty })
let ndxPts = spark["^NDX"]!.points
check("纳指100 有 79 个点，按时间排好", ndxPts.count == 79 && zip(ndxPts, ndxPts.dropFirst()).allSatisfy { $0.time < $1.time })
check("每个指数的最后一个点都不晚于它的最新价时间", spark.values.allSatisfy { $0.points.last!.time <= $0.time })
check("Yahoo 来源的报价带上走势", combined.first { $0.id == "NDX" }?.intraday?.count == 79)
let sseYahooPts = spark["000001.SS"]!.points
check("上证用新浪价：Yahoo 的 \(sseYahooPts.count) 个点后面接上新浪 15:35 这一个",
      sseQ.intraday?.count == sseYahooPts.count + 1 && sseQ.intraday?.last == PricePoint(time: sse.time, price: sse.price))
check("新浪更旧：走势就是 Yahoo 的", IndexService.combine(yahoo: spark, sina: ["sh000001": oldSina]).first { $0.id == "SSE" }?.intraday == sseYahooPts)
let nextDaySina = SinaQuote(code: "sh000001", name: "上证指数", open: 1, previousClose: 1, price: 1, high: 1, low: 1,
                            time: at("2026-10-09 09:35:00", "Asia/Shanghai"))
check("新浪已是第二天、Yahoo 走势还是前一天：不硬拼，走势留空",
      IndexService.combine(yahoo: spark, sina: ["sh000001": nextDaySina]).first { $0.id == "SSE" }?.intraday == nil)
check("新浪单独有价（Yahoo 挂了）：没有走势", sinaOnly[0].intraday == nil)

section("迷你走势线的横轴")
let ftse = spark["^FTSE"]!, twii = spark["^TWII"]!
check("富时（交易中，最后一点 15:27）：横轴是整个交易时段，线只占前面一小段",
      SparkDomain.xRange(points: ftse.points, session: ftse.session) == ftse.session!.start...ftse.session!.end)
check("台湾加权（已收盘）：横轴是当天时段", SparkDomain.xRange(points: twii.points, session: twii.session) == twii.session!.start...twii.session!.end)
let shifted = Session(start: ftse.session!.start.addingTimeInterval(86400), end: ftse.session!.end.addingTimeInterval(86400))
check("时段已经是下一个交易日的：改用数据自己的首尾",
      SparkDomain.xRange(points: ftse.points, session: shifted) == ftse.points.first!.time...ftse.points.last!.time)
check("只有一个点：不画", SparkDomain.xRange(points: [ftse.points[0]], session: nil) == nil)

section("快照兼容旧格式")
let oldJSON = #"{"id":"NDX","price":31160.08,"previousClose":31224.69,"time":"2026-10-08T07:00:00Z","source":"yahoo"}"#
let jd = JSONDecoder(); jd.dateDecodingStrategy = .iso8601
let oldQuote = try? jd.decode(IndexQuote.self, from: Data(oldJSON.utf8))
check("没有走势字段的旧报价照样能读，走势为空", oldQuote != nil && oldQuote?.intraday == nil)
let oldBoard = try? jd.decode(IndexBoard.self, from: Data(#"{"quotes":[],"fetchedAt":"2026-10-08T07:00:00Z"}"#.utf8))
check("没有金价字段的旧快照照样能读，金价为空", oldBoard != nil && oldBoard?.gold == nil)
let userSnapshot = SnapshotStore.default()
if FileManager.default.fileExists(atPath: userSnapshot.fileURL.path) {
    check("这台 Mac 上现有的快照文件能用新代码读出来", userSnapshot.load() != nil)
}

// MARK: - 详情图：分时 + 日K / 周K / 月K
section("详情图：周期")
check("指数：分时、日K、周K、月K；汇率：日K、周K、月K", ChartPeriod.indexPeriods.map(\.label) == ["分时", "日K", "周K", "月K"]
      && ChartPeriod.fxPeriods.map(\.label) == ["日K", "周K", "月K"])
check("请求参数：1d·1m、10y·1d、20y·1wk、30y·1mo（不用 max，Yahoo 会降成季线）",
      ChartPeriod.indexPeriods.map { YahooChartParser.url(symbol: "^GSPC", period: $0).query ?? "" }
        == ["range=1d&interval=1m", "range=10y&interval=1d", "range=20y&interval=1wk", "range=30y&interval=1mo"])
check("URL 里 ^ 编码成 %5E、上证的点保留", YahooChartParser.url(symbol: "^GSPC", period: .daily).absoluteString.contains("chart/%5EGSPC?")
      && YahooChartParser.url(symbol: "000001.SS", period: .daily).absoluteString.contains("chart/000001.SS?"))
let quarterly = #"{"chart":{"result":[{"meta":{"dataGranularity":"3mo","exchangeTimezoneName":"America/New_York"},"timestamp":[1,2],"indicators":{"quote":[{"open":[1,1],"high":[1,1],"low":[1,1],"close":[1,1]}]}}]}}"#
check("要月K 却给了季线：当成失败，不画错的 K 线", (try? YahooChartParser.parse(Data(quarterly.utf8), period: .monthly, fetchedAt: Date())) == nil)

section("同一根 K 线（按交易所当地时间，周一开始的 ISO 周）")
let nyTZ = TimeZone(identifier: "America/New_York")!, taipei = TimeZone(identifier: "Asia/Taipei")!
func ny(_ s: String) -> Date { at(s, "America/New_York") }
check("分时：同一分钟是同一根，跨分钟不是", ChartPeriod.intraday.sameCandle(ny("2026-10-08 12:15:01"), ny("2026-10-08 12:15:59"), timeZone: nyTZ)
      && !ChartPeriod.intraday.sameCandle(ny("2026-10-08 12:15:59"), ny("2026-10-08 12:16:00"), timeZone: nyTZ))
check("日K：纽约同一天是同一根，过了纽约午夜不是", ChartPeriod.daily.sameCandle(ny("2026-10-08 09:30:00"), ny("2026-10-08 23:59:00"), timeZone: nyTZ)
      && !ChartPeriod.daily.sameCandle(ny("2026-10-08 23:59:00"), ny("2026-10-09 00:01:00"), timeZone: nyTZ))
check("周K：周一到周日同一根，周日和下周一不是", ChartPeriod.weekly.sameCandle(ny("2026-10-05 09:30:00"), ny("2026-10-11 12:00:00"), timeZone: nyTZ)
      && !ChartPeriod.weekly.sameCandle(ny("2026-10-11 12:00:00"), ny("2026-10-12 09:30:00"), timeZone: nyTZ))
check("周K 跨年：2026-12-31（周四）和 2027-01-01（周五）是同一周", ChartPeriod.weekly.sameCandle(ny("2026-12-31 10:00:00"), ny("2027-01-01 10:00:00"), timeZone: nyTZ))
check("月K：10/31 和 11/1 不是同一根", !ChartPeriod.monthly.sameCandle(ny("2026-10-31 10:00:00"), ny("2026-11-01 10:00:00"), timeZone: nyTZ))

section("K 线解析（真实样本，北京时间 10/9 01:13 抓：标普盘中、台湾加权已收盘；期望值由 Python 从原始 JSON 独立算出）")
let chartNow = ISO8601DateFormatter().date(from: String(data: fixture("chart_k.fetched_at"), encoding: .utf8)!
    .trimmingCharacters(in: .whitespacesAndNewlines))!
let fileOf: [ChartPeriod: String] = [.intraday: "intraday", .daily: "daily", .weekly: "weekly", .monthly: "monthly"]
func chart(_ name: String, _ p: ChartPeriod) -> ChartSeries {
    try! YahooChartParser.parse(fixture("chart_\(name)_\(fileOf[p]!).json"), period: p, fetchedAt: chartNow)
}
func ohlc(_ p: PricePoint) -> [Double] { [p.candleOpen, p.candleHigh, p.candleLow, p.price] }
func near4(_ a: [Double], _ b: [Double], _ tol: Double = 0.005) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) <= tol } && a.count == b.count }
let gI = chart("GSPC", .intraday), gD = chart("GSPC", .daily), gW = chart("GSPC", .weekly), gM = chart("GSPC", .monthly)
let tI = chart("TWII", .intraday), tD = chart("TWII", .daily), tW = chart("TWII", .weekly), tM = chart("TWII", .monthly)
check("标普 分时：223 个（每分钟），昨收 7801.77，当日最高 7797.79、最低 7744.53",
      gI.points.count == 223 && near(gI.baseline, 7801.77) && near(gI.high, 7797.79, 0.005) && near(gI.low, 7744.53, 0.005))
check("标普 日K：10 年 2513 根；第一根 2016-10-10 开高低收 2160.39/2169.60/2160.39/2163.66",
      gD.points.count == 2513 && near4(ohlc(gD.points[0]), [2160.39, 2169.60, 2160.39, 2163.66]))
check("标普 日K：最后一根是 10/8（盘中）7778.45/7797.79/7744.53/7755.18；十年最高 7844.52、最低 2083.79",
      near4(ohlc(gD.points.last!), [7778.45, 7797.79, 7744.53, 7755.18]) && near(gD.high, 7844.52, 0.005) && near(gD.low, 2083.79, 0.005))
check("标普 周K：20 年 1044 根（当周两行合并）；最后一根是 10/5 当周 7730.86/7844.52/7727.59/7755.28；最低 666.79（2009）",
      gW.points.count == 1044 && near4(ohlc(gW.points.last!), [7730.86, 7844.52, 7727.59, 7755.28]) && near(gW.low, 666.79, 0.005))
check("标普 月K：30 年 360 根；第一根 1996-11 是 705.27/762.12/701.30/757.02",
      gM.points.count == 360 && near4(ohlc(gM.points[0]), [705.27, 762.12, 701.30, 757.02]))
check("台湾加权 分时 271 个，昨收 49822.6；日K 2430 根，最后一根还是 10/7（Yahoo 还没补 10/8）",
      tI.points.count == 271 && near(tI.baseline, 49822.6) && tD.points.count == 2430
      && near4(ohlc(tD.points.last!), [49857.32, 49966.89, 49567.52, 49806.37], 0.01))
check("台湾加权 周K 1029 根、月K 351 根", tW.points.count == 1029 && tM.points.count == 351)
let allK = [gI, gD, gW, gM, tI, tD, tW, tM]
check("每根都满足 最低 ≤ 开、收 ≤ 最高", allK.allSatisfy { $0.points.allSatisfy {
    $0.candleLow <= min($0.candleOpen, $0.price) && max($0.candleOpen, $0.price) <= $0.candleHigh } })
check("按时间排好，相邻两根不会属于同一根 K 线（按各自交易所时区）", zip(allK, [nyTZ, nyTZ, nyTZ, nyTZ, taipei, taipei, taipei, taipei]).allSatisfy { s, tz in
    zip(s.points, s.points.dropFirst()).allSatisfy { $0.time < $1.time && !s.period.sameCandle($0.time, $1.time, timeZone: tz) } })

section("K 线末尾并上面板最新价")
let twClose = at("2026-10-08 13:31:15", "Asia/Taipei")
let tDFilled = tD.updatingLatest(price: 49313.44, time: twClose, today: tI, timeZone: taipei)
check("台湾加权 日K：补上 10/8 这根 → 2431 根；开高低用当天分时 49783.06/49783.06/49189.77，收 49313.44",
      tDFilled.points.count == 2431 && near4(ohlc(tDFilled.points.last!), [49783.06, 49783.06, 49189.77, 49313.44], 0.01), "\(ohlc(tDFilled.points.last!))")
check("没有当天分时可用：补一根开高低收相同的",
      near4(ohlc(tD.updatingLatest(price: 49313.44, time: twClose, today: nil, timeZone: taipei).points.last!), [49313.44, 49313.44, 49313.44, 49313.44]))
check("台湾加权 周K：10/8 在当周 → 并进最后一根，不多一根", tW.updatingLatest(price: 49313.44, time: twClose, today: tI, timeZone: taipei).points.count == 1029)
let gLast = gD.points.last!
let gMerged = gD.updatingLatest(price: 7760, time: gLast.time.addingTimeInterval(3 * 3600), today: gI, timeZone: nyTZ)
check("标普 日K：同一天的新价格 → 并进今天那根（收 7760，最高最低不变）", gMerged.points.count == 2513
      && near4(ohlc(gMerged.points.last!), [7778.45, 7797.79, 7744.53, 7760]))
let gILast = gI.points.last!
check("分时：同一分钟并进去；下一分钟另起一个点；第二天不接",
      gI.updatingLatest(price: 1, time: gILast.time.addingTimeInterval(5), today: nil, timeZone: nyTZ).points.count == 223
      && gI.updatingLatest(price: 1, time: gILast.time.addingTimeInterval(120), today: nil, timeZone: nyTZ).points.count == 224
      && gI.updatingLatest(price: 1, time: gILast.time.addingTimeInterval(86400), today: nil, timeZone: nyTZ) == gI)
check("更早的价格：不变", gD.updatingLatest(price: 1, time: gLast.time.addingTimeInterval(-60), today: nil, timeZone: nyTZ) == gD)

section("K 线视窗：拖动、缩放（同花顺那样）")
var vp = KLineViewport()
check("默认一屏 60 根，贴着最新：2453…2512", vp.visible(total: 2513) == 2453...2512 && vp.right == nil)
vp.pan(by: -10, total: 2513)
check("往左挪 10 根：2443…2502", vp.visible(total: 2513) == 2443...2502)
check("挪开以后来了新数据，视窗停在原处，不跳回最新", vp.visible(total: 2514) == 2443...2502)
vp.pan(by: 100, total: 2513)
check("往右挪到底：恢复「跟着最新」", vp.right == nil && vp.visible(total: 2513) == 2453...2512)
vp.pan(by: -100000, total: 2513)
check("往左挪过头：停在最早一屏 0…59", vp.visible(total: 2513) == 0...59)
var vz = KLineViewport()
vz.zoom(by: 2, total: 2513)
check("放大 2 倍：一屏 30 根，右边不动", vz.count == 30 && vz.visible(total: 2513) == 2483...2512)
vz.zoom(by: 0.01, total: 2513); let maxC = vz.count
vz.zoom(by: 100, total: 2513)
check("缩放有上下限：最多 250 根、最少 20 根", maxC == 250 && vz.count == 20)
var vl = KLineViewport(count: 60, right: 30)
vl.zoom(by: 0.5, total: 2513)
check("在最左边缩小：左边不越过第 0 根", vl.visible(total: 2513)?.lowerBound == 0 && vl.visible(total: 2513)?.count == 120)
check("总共不到一屏：全部显示；没有数据：nil", KLineViewport().visible(total: 15) == 0...14 && KLineViewport().visible(total: 0) == nil)

section("汇率 K 线：由美元货币对换算（不用 Yahoo 直接交叉盘）")
func fxk(_ code: String, _ p: ChartPeriod) -> ChartSeries {
    let pair = USDPair.pair(for: code)!
    return FXCross.perUSD(try! YahooChartParser.parse(fixture("fxk_\(code)_\(fileOf[p]!).json"), period: p, fetchedAt: chartNow), pair: pair)
}
let perUSDDaily = ["CNY": fxk("CNY", .daily), "JPY": fxk("JPY", .daily), "TWD": fxk("TWD", .daily)]
let lonTZ = FXCalendar.timeZone
func onDay(_ s: ChartSeries, _ ymd: String) -> PricePoint? { s.points.first { FXCalendar.ymd($0.time) == ymd } }
let jpyCny = FXCross.series(FXPairSpec(from: "JPY", to: "CNY", unit: 100), perUSD: perUSDDaily)!
check("100日元 → 人民币 10/7：开高低收 4.2348/4.2466/4.2301/4.2354，收盘和面板汇率表（4.2354）一致",
      near4(ohlc(onDay(jpyCny, "2026-10-07")!), [4.2348, 4.2466, 4.2301, 4.2354], 0.0001) && near(onDay(jpyCny, "2026-10-07")!.price, 4.2354, 0.00005))
let cnyTwd = FXCross.series(FXPairSpec(from: "CNY", to: "TWD"), perUSD: perUSDDaily)!
check("1人民币 → 新台币 10/7：4.7397/4.7559/4.7387/4.7396，和面板汇率表（4.7396）一致",
      near4(ohlc(onDay(cnyTwd, "2026-10-07")!), [4.7397, 4.7559, 4.7387, 4.7396], 0.0001))
let usdTwd = FXCross.series(FXPairSpec(from: "USD", to: "TWD"), perUSD: perUSDDaily)!
check("1美元 → 新台币：直接就是 TWD=X，10/7 开高低收 31.7770/31.8860/31.7704/31.7769",
      near4(ohlc(onDay(usdTwd, "2026-10-07")!), [31.7770, 31.8860, 31.7704, 31.7769], 0.0001))
let twdUsd = FXCross.series(FXPairSpec(from: "TWD", to: "USD", unit: 100), perUSD: perUSDDaily)!
check("100新台币 → 美元：TWD=X 取倒数 ×100，最高 = 100/最低", near(onDay(twdUsd, "2026-10-07")!.candleHigh, 100 / 31.7704, 1e-6))
check("换算出的每根都满足 最低 ≤ 开、收 ≤ 最高", [jpyCny, cnyTwd, usdTwd, twdUsd].allSatisfy { $0.points.allSatisfy {
    $0.candleLow <= min($0.candleOpen, $0.price) + 1e-12 && max($0.candleOpen, $0.price) <= $0.candleHigh + 1e-12 } })
check("按日期配对：日K 两边都有的天数（约 2600 天）", (2590...2601).contains(jpyCny.points.count) && (2590...2601).contains(cnyTwd.points.count))
let direct = try! YahooChartParser.parse(fixture("fxk_TWDCNY_daily.json"), period: .daily, fetchedAt: chartNow)
let twdCny = FXCross.series(FXPairSpec(from: "TWD", to: "CNY"), perUSD: perUSDDaily)!
let bad = onDay(direct, "2026-10-08")!.price, good = onDay(twdCny, "2026-10-08")!.price
check("为什么不用直接交叉盘：TWDCNY=X 10/8 收 0.2012，换算是 0.2095，差 4%（新台币不可能一天跌 4%）",
      near(bad, 0.2012, 0.00005) && near(good, 0.20954, 0.0001) && abs(bad / good - 1) > 0.035, "\(bad) \(good)")
for (p, n) in [(ChartPeriod.weekly, 1000), (.monthly, 250)] {
    let s = FXCross.series(FXPairSpec(from: "JPY", to: "CNY", unit: 100), perUSD: ["CNY": fxk("CNY", p), "JPY": fxk("JPY", p)])!
    check("\(p.label)：100日元 → 人民币 有 \(s.points.count) 根（≥\(n)）", s.points.count >= n)
}
let monthlyTWD = FXCross.series(FXPairSpec(from: "CNY", to: "TWD"), perUSD: ["CNY": fxk("CNY", .monthly), "TWD": fxk("TWD", .monthly)])!
check("月K：新台币 2004 年起才有，配对后从 2004 年开始", Calendar(identifier: .gregorian).component(.year, from: monthlyTWD.points.first!.time) == 2004)

section("汇率：削掉 Yahoo 数据里不可能的影线（只削最高/最低，开收不动）")
func rawFX(_ code: String, _ p: ChartPeriod) -> ChartSeries {
    try! YahooChartParser.parse(fixture("fxk_\(code)_\(fileOf[p]!).json"), period: p, fetchedAt: chartNow)
}
let rawTWDm = rawFX("TWD", .monthly), cleanTWDm = fxk("TWD", .monthly)
check("开收本身就坏的整根丢掉：新台币月线 2014-12（收 3.67）、周线 2013-09-08（开 0.001）各丢 1 根，日线和人民币、日元不丢",
      rawTWDm.droppingBadCandles(maxJump: 0.3).dropped == 1 && rawFX("TWD", .weekly).droppingBadCandles(maxJump: 0.3).dropped == 1
      && rawFX("TWD", .daily).droppingBadCandles(maxJump: 0.3).dropped == 0
      && ChartPeriod.fxPeriods.allSatisfy { p in ["CNY", "JPY"].allSatisfy { rawFX($0, p).droppingBadCandles(maxJump: 0.3).dropped == 0 } })
check("指数用同样的规则一根都不会丢（标普十年日K、三十年月K）", gD.droppingBadCandles(maxJump: 0.3).dropped == 0 && gM.droppingBadCandles(maxJump: 0.3).dropped == 0)
check("新台币月线：原始最低 0.001，削完后最低 > 25", (rawTWDm.low ?? 1) < 0.01 && (cleanTWDm.low ?? 0) > 25, "\(cleanTWDm.low ?? .nan)")
check("日元月线：原始最高 635，削完后 < 200", (rawFX("JPY", .monthly).high ?? 0) > 600 && (fxk("JPY", .monthly).high ?? 999) < 200)
check("人民币周线：原始最低 2.2，削完后 > 5.5", (rawFX("CNY", .weekly).low ?? 9) < 2.3 && (fxk("CNY", .weekly).low ?? 0) > 5.5)
let twdDailyClamp = rawFX("TWD", .daily).clampingWicks(minimumCap: 0.01)
check("新台币日线：削了 \(twdDailyClamp.clamped) 根（占比 < 5%），开收一根没动",
      twdDailyClamp.clamped > 0 && twdDailyClamp.clamped < 130
      && zip(twdDailyClamp.series.points, rawFX("TWD", .daily).points).allSatisfy { $0.price == $1.price && $0.candleOpen == $1.candleOpen })
let idxClamp = gM.clampingWicks(minimumCap: 0.04)
check("同样的规则要是用在标普月线上会误削 \(idxClamp.clamped) 根（含 2020 年 3 月真实的长下影线）——所以指数不削", idxClamp.clamped > 0)
check("10/7 这种正常的 K 线不受影响（上面的 10/7 数值都在削之后验证）", near(onDay(usdTwd, "2026-10-07")!.candleLow, 31.7704, 0.0001))

section("汇率表每一行对应的货币对")
let tablesWithPairs = FXTables.build(fx)
check("人民币表：100日元、1美元、1欧元、100新台币、100港币 → 人民币", tablesWithPairs[0].rows.map(\.pair.id)
      == ["JPY>CNY×100", "USD>CNY×1", "EUR>CNY×1", "TWD>CNY×100", "HKD>CNY×100"])
check("新台币表：1人民币、100日元、1美元、1欧元、1港币 → 新台币", tablesWithPairs[1].rows.map(\.pair.id)
      == ["CNY>TWD×1", "JPY>TWD×100", "USD>TWD×1", "EUR>TWD×1", "HKD>TWD×1"])
check("美元表：1美元 → 人民币、日元、欧元、新台币、港币", tablesWithPairs[2].rows.map(\.pair.id)
      == ["USD>CNY×1", "USD>JPY×1", "USD>EUR×1", "USD>TWD×1", "USD>HKD×1"])
check("「1人民币 → 新台币」用 TWD=X ÷ CNY=X，不用没有历史的 CNYTWD=X", FXPairSpec(from: "CNY", to: "TWD").legs.map(\.yahooSymbol) == ["CNY=X", "TWD=X"])
check("美元直接货币对标成精确，其余标成换算", FXPairSpec(from: "USD", to: "JPY").isDirect && !FXPairSpec(from: "JPY", to: "CNY").isDirect
      && FXPairSpec(from: "JPY", to: "CNY").sourceNote.contains("上下限"))
check("标题：100日元 → 人民币", FXPairSpec(from: "JPY", to: "CNY", unit: 100).title == "100日元 → 人民币")

section("迷你走势线的拼接不受影响（上证接新浪价用的是 appending）")
check("同一天、更晚 → 接上", gI.appending(PricePoint(time: gILast.time.addingTimeInterval(120), price: 1), timeZone: nyTZ).points.count == 224)
check("更早的价格 → 不接", gI.appending(PricePoint(time: gILast.time.addingTimeInterval(-60), price: 1), timeZone: nyTZ) == gI)
check("第二天的价格 → 不接", gI.appending(PricePoint(time: gILast.time.addingTimeInterval(86400), price: 1), timeZone: nyTZ) == gI)

section("价格点兼容旧快照")
let oldPoint = try? jd.decode(PricePoint.self, from: Data(#"{"time":"2026-10-08T07:00:00Z","price":1.5}"#.utf8))
check("旧格式（只有时间和价格）能读；开高低为空，画 K 线时按收盘补", oldPoint?.open == nil && oldPoint?.candleOpen == 1.5
      && oldPoint?.candleHigh == 1.5 && oldPoint?.candleLow == 1.5)
let je = JSONEncoder(); je.dateEncodingStrategy = .iso8601
let encodedLine = String(data: try! je.encode(PricePoint(time: chartNow, price: 1)), encoding: .utf8)!
check("走势线的点存盘时不会多写开高低字段", !encodedLine.contains("open") && !encodedLine.contains("high"), encodedLine)

section("按需抓取和缓存")
final class NetState: @unchecked Sendable { var calls = 0; var down = false; var urls: [String] = [] }
struct ChartMock: HTTPFetching {
    let state: NetState
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        state.calls += 1; state.urls.append(url.absoluteString)
        if state.down { throw URLError(.notConnectedToInternet) }
        let q = url.query ?? ""
        let kind = q.contains("interval=1m") ? "intraday" : q.contains("interval=1d") ? "daily" : q.contains("interval=1wk") ? "weekly" : "monthly"
        let path = url.path
        if path.contains("%5EGSPC") || path.contains("^GSPC") { return fixture("chart_GSPC_\(kind).json") }
        for c in ["CNY", "JPY", "TWD"] where path.hasSuffix("/\(c)=X") || path.hasSuffix("/\(c)%3DX") { return fixture("fxk_\(c)_\(kind).json") }
        throw URLError(.fileDoesNotExist)
    }
}
let net = NetState()
let svc = ChartService(fetcher: ChartMock(state: net))
let first = run { try! await svc.series(symbol: "^GSPC", period: .intraday, now: chartNow) }
let again = run { try! await svc.series(symbol: "^GSPC", period: .intraday, now: chartNow.addingTimeInterval(30)) }
check("30 秒内再看分时：用缓存，不再请求", net.calls == 1 && first == again)
_ = run { try! await svc.series(symbol: "^GSPC", period: .intraday, now: chartNow.addingTimeInterval(61)) }
check("超过 1 分钟：重新请求", net.calls == 2)
_ = run { try! await svc.series(symbol: "^GSPC", period: .weekly, now: chartNow) }
_ = run { try! await svc.series(symbol: "^GSPC", period: .weekly, now: chartNow.addingTimeInterval(1800)) }
check("周K 单独缓存，1 小时内不重抓", net.calls == 3)
_ = run { try! await svc.series(symbol: "^GSPC", period: .weekly, now: chartNow.addingTimeInterval(1800), force: true) }
check("点「重试」强制刷新：重新请求", net.calls == 4)
net.down = true
let stale = run { try? await svc.series(symbol: "^GSPC", period: .intraday, now: chartNow.addingTimeInterval(600)) }
check("断网但有旧数据：先显示旧的", stale?.points.count == 223)
let fresh = ChartService(fetcher: ChartMock(state: net))
check("断网又没缓存：报错（界面显示「重试」）", run { (try? await fresh.series(symbol: "^GSPC", period: .monthly, now: chartNow)) == nil })
let fxNet = NetState()
let fxSvc = ChartService(fetcher: ChartMock(state: fxNet))
let loaded = run { try! await FXCross.load(FXPairSpec(from: "JPY", to: "CNY", unit: 100), period: .daily, service: fxSvc, force: false) }
check("汇率 K 线：100日元 → 人民币 抓 CNY=X 和 JPY=X 两个，拼出来的 K 线和上面一样", fxNet.calls == 2 && loaded.points == jpyCny.points,
      "calls=\(fxNet.calls) \(loaded.points.count) vs \(jpyCny.points.count)")
_ = run { try! await FXCross.load(FXPairSpec(from: "USD", to: "TWD"), period: .daily, service: fxSvc, force: false) }
check("1美元 → 新台币 只抓 TWD=X 一个", fxNet.calls == 3 && fxNet.urls.last!.contains("TWD%3DX"))
_ = run { try! await FXCross.load(FXPairSpec(from: "CNY", to: "TWD"), period: .daily, service: fxSvc, force: false) }
check("1人民币 → 新台币：CNY=X、TWD=X 都已缓存，不再请求", fxNet.calls == 3)

// MARK: - 面板缩放
section("面板自适应（先缩字号到 0.75 倍，再整块收起内容；拉大最多 1.8 倍）")
// 真实测出来的 7 档在 1 倍时需要的大小（PaneSnapshots 会打印；改了排版要同步）
let tierSizes: [PaneScale.Size] = [(642, 468), (642, 449), (642, 401), (590, 449), (590, 401), (534, 449), (534, 401)]
func pick(_ w: Double, _ h: Double) -> (tier: Int, scale: Double) { PaneScale.choose(width: w, height: h, tiers: tierSizes) }
check("和完整内容一样大：第 0 档、1 倍", pick(642, 468) == (0, 1))
check("缩小到 0.8 倍：还是完整一档，字号跟着缩到 0.8", pick(642 * 0.8, 468 * 0.8).tier == 0 && abs(pick(642 * 0.8, 468 * 0.8).scale - 0.8) < 1e-9)
check("正好 0.75 倍：还是完整一档", pick(642 * 0.75, 468 * 0.75).tier == 0)
check("宽不够（450×470）：收掉汇率多余的表和走势线（第 3 档），字号回到约 0.76", pick(450, 470).tier == 3 && abs(pick(450, 470).scale - 450.0 / 590) < 1e-9)
check("宽够、只是矮（900×310）：收汇率和分区标题（第 2 档），走势线还在", pick(900, 310).tier == 2)
check("拉得很大：完整一档、封顶 1.8 倍", pick(3000, 3000) == (0, 1.8))
check("只拉宽不拉高：按较小的方向算，仍是 1 倍（多出来的宽度让两列伸展）", pick(1200, 468) == (0, 1))
check("小得放不下任何一档：用最紧凑那档，只缩字号（内容仍然完整）", pick(100, 100).tier == 6 && abs(pick(100, 100).scale - 100.0 / 534) < 1e-9)
let loSize = PaneScale.minSize(compact: tierSizes.last!)
let hiSize = PaneScale.maxSize(full: tierSizes[0], screenWidth: 1408, screenHeight: 761)
check("最小尺寸 = 最紧凑一档 × 0.75；最大 = 完整一档 × 1.8 但不超过屏幕（1408×761 的屏幕上是 1155.6×761）",
      abs(loSize.width - 400.5) < 1e-9 && abs(loSize.height - 300.75) < 1e-9 && abs(hiSize.width - 1155.6) < 1e-9 && hiSize.height == 761)
var worst = (w: 0.0, h: 0.0, why: "")
var windows = 0
for w in stride(from: loSize.width, through: hiSize.width, by: 7) {
    for h in stride(from: loSize.height, through: hiSize.height, by: 7) {
        windows += 1
        let r = pick(w, h), t = tierSizes[r.tier]
        if t.width * r.scale > w + 1e-9 || t.height * r.scale > h + 1e-9 { worst = (w, h, "放不下，会被切一半"); break }
        if r.scale < PaneScale.minScale - 1e-9 { worst = (w, h, "字号小于 0.75 倍"); break }
    }
    if !worst.why.isEmpty { break }
}
check("从最小到最大的任何大小（共 \(windows) 种）：选中的一档完整放得下、字号不小于 0.75 倍", worst.why.isEmpty, "\(worst)")

// MARK: - 真实网络（加 --live 才跑）
if CommandLine.arguments.contains("--live") {
    section("真实网络")
    let now = Date()
    let live = run { await IndexService().fetch(asOf: now) }
    let bj = DateFormatter(); bj.timeZone = TimeZone(identifier: "Asia/Shanghai"); bj.dateFormat = "MM-dd HH:mm"
    for q in live.quotes {
        print(String(format: "    %@ %@ %.2f %@ %@", IndexSpec.spec(q.id)!.name, q.isTrading(at: now) ? "交易中" : "休市",
                     q.price, q.changePercent.map { String(format: "%+.2f%%", $0) } ?? "-", "价格时间 \(bj.string(from: q.time)) \(q.source.rawValue)"))
    }
    check("12 个指数都抓到", live.quotes.count == 12)
    let liveFX = run { await FXService().fetch(asOf: now) }
    for t in FXTables.build(liveFX) {
        print("    \(t.title)（\(t.subtitle)）: " + t.rows.map { "\($0.label) \($0.value.map { String(format: "%.4f", $0) } ?? "—")" }.joined(separator: "  "))
    }
    check("汇率 5 个货币对都有且不落后（\(liveFX.expectedDate)）", liveFX.missing(in: PaneContent.standard.currencies).isEmpty && !liveFX.isStale)
    let liveCharts = ChartService()
    for p in ChartPeriod.indexPeriods {
        let s = run { try? await liveCharts.series(symbol: "^GSPC", period: p, force: true) }
        check("真实网络 标普 \(p.label)：\(s?.points.count ?? 0) 根，粒度对得上", (s?.points.count ?? 0) > (p == .intraday ? 0 : 200))
    }
    for p in ChartPeriod.fxPeriods {
        let s = run { try? await FXCross.load(FXPairSpec(from: "JPY", to: "CNY", unit: 100), period: p, service: liveCharts, force: true) }
        check("真实网络 100日元 → 人民币 \(p.label)：\(s?.points.count ?? 0) 根，最新收盘 \(s?.points.last.map { String(format: "%.4f", $0.price) } ?? "—")",
              (s?.points.count ?? 0) > 200)
    }
}

print("\n\(total - failures)/\(total) 通过")
exit(failures == 0 ? 0 : 1)
