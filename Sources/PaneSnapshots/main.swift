import SwiftUI
import AppKit
import PaneCore
import PaneUI

// 用法：swift run PaneSnapshots <输出目录>
// 指数和汇率用 Fixtures 里的真实样本（北京时间 2026-10-08 15:42 抓取）；伦敦金用新浪样本（10-09 00:56 抓取，所以截图里它的时间比标题栏晚）。

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let fixtures = root.appendingPathComponent("Fixtures")
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "shots")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct FixtureFetcher: HTTPFetching {
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        let s = url.absoluteString
        func f(_ n: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(n)) }
        if s.contains("spark") { return try f("spark_indices.json") }
        if s.contains("sinajs") { return try f("sina_sh000001.txt") + Data("\n".utf8) + f("sina_hf_XAU.txt") }  // 上证 + 伦敦金同一个请求
        if s.contains("frankfurter") { return try f("ecb_usd.json") }
        for (sym, file) in [("EURUSD%3DX", "fxd_EURUSD.json"), ("CNY%3DX", "fxd_CNY.json"), ("JPY%3DX", "fxd_JPY.json"),
                            ("TWD%3DX", "fxd_TWD.json"), ("HKD%3DX", "fxd_HKD.json")] where s.contains("chart/\(sym)") {
            return try f(file)
        }
        throw URLError(.cannotFindHost)
    }
}

let sampleNow = ISO8601DateFormatter().date(from: try String(contentsOf: fixtures.appendingPathComponent("spark_indices.fetched_at"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines))!
let indices = await IndexService(fetcher: FixtureFetcher()).fetch(asOf: sampleNow)
let fx = await FXService(fetcher: FixtureFetcher()).fetch(asOf: sampleNow)
let snapshot = PaneSnapshot(generatedAt: sampleNow, indices: indices, fx: fx)

@MainActor func render<V: View>(_ name: String, _ view: V, scheme: ColorScheme) {
    let card = view
        .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay { PanelBorder() }
        .environment(\.colorScheme, scheme)
        .environment(\.chartInteraction, false)
    let r = ImageRenderer(content: card); r.scale = 2
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("渲染失败 \(name)"); return }
    try! png.write(to: out.appendingPathComponent("\(name).png"))
    print("  \(name).png  \(Int(img.size.width))×\(Int(img.size.height))")
}

await MainActor.run {
    for scheme in [ColorScheme.light, .dark] {
        let tag = scheme == .dark ? "dark" : "light"
        render("panel-\(tag)", PanelView(snapshot: snapshot, now: sampleNow, draggable: false), scheme: scheme)
    }
    var green = snapshot; green.settings.upIsRed = false
    render("panel-greenup", PanelView(snapshot: green, now: sampleNow, draggable: false), scheme: .light)
    render("panel-empty", PanelView(snapshot: PaneSnapshot(generatedAt: sampleNow), now: sampleNow, draggable: false), scheme: .light)
}

// Yahoo 挂掉、汇率只剩欧洲央行（没有新台币）的样子
struct YahooDown: HTTPFetching {
    func data(from url: URL, headers: [String: String]) async throws -> Data {
        if url.absoluteString.contains("yahoo") { throw URLError(.timedOut) }
        return try await FixtureFetcher().data(from: url, headers: headers)
    }
}
let fxECB = await FXService(fetcher: YahooDown()).fetch(asOf: sampleNow)
await MainActor.run {
    render("panel-no-twd", PanelView(snapshot: PaneSnapshot(generatedAt: sampleNow, indices: indices, fx: fxECB), now: sampleNow,
                                     draggable: false), scheme: .light)
}

// 自适应：同一份数据放进不同大小的面板，看自动选的档位和字号
await MainActor.run {
    let tiers = AdaptivePanel.idealSizes(snapshot: snapshot, now: sampleNow)
    for (i, sz) in tiers.enumerated() { print("  档位 \(i) 在 1 倍时需要 \(Int(sz.width))×\(Int(sz.height))") }
    let lo = PaneScale.minSize(compact: (tiers.last!.width, tiers.last!.height))
    let sizes: [(String, Double, Double)] = [
        ("base", tiers[0].width, tiers[0].height),
        ("large", 1000, 700),
        ("scaled-0.8", tiers[0].width * 0.8, tiers[0].height * 0.8),
        ("wide", 900, 468),
        ("wide-short", 900, 310),
        ("narrow", 450, 470),
        ("small", 420, 280),
        ("min", lo.width, lo.height),
    ]
    for (name, w, h) in sizes {
        let pick = PaneScale.choose(width: w, height: h, tiers: tiers.map { ($0.width, $0.height) })
        print("  \(name) \(Int(w))×\(Int(h)) → 第 \(pick.tier) 档，\(String(format: "%.2f", pick.scale)) 倍")
        render("adaptive-\(name)", AdaptivePanel(snapshot: snapshot, now: sampleNow, tierSizes: tiers).frame(width: w, height: h), scheme: .light)
    }
    render("adaptive-large-dark", AdaptivePanel(snapshot: snapshot, now: sampleNow, tierSizes: tiers).frame(width: 1000, height: 700), scheme: .dark)
}

// 周末：伦敦金显示收盘日（纽约周五）
await MainActor.run {
    let saturday = ISO8601DateFormatter().date(from: "2026-10-10T04:00:00Z")!
    render("panel-weekend", PanelView(snapshot: snapshot, now: saturday, draggable: false), scheme: .light)
}

// 详情窗口：分时 + 日K / 周K / 月K，汇率 K 线（Fixtures 里 chart_*_{intraday,daily,weekly,monthly} 和 fxk_*，北京时间 10/9 01:13 前后抓取）
let chartNow = ISO8601DateFormatter().date(from: try String(contentsOf: fixtures.appendingPathComponent("chart_k.fetched_at"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines))!
let fileOf: [ChartPeriod: String] = [.intraday: "intraday", .daily: "daily", .weekly: "weekly", .monthly: "monthly"]
func loadCharts(_ name: String) throws -> [ChartPeriod: ChartSeries] {
    var out: [ChartPeriod: ChartSeries] = [:]
    for p in ChartPeriod.indexPeriods {
        out[p] = try YahooChartParser.parse(Data(contentsOf: fixtures.appendingPathComponent("chart_\(name)_\(fileOf[p]!).json")),
                                            period: p, fetchedAt: chartNow)
    }
    return out
}
func local(_ s: String, _ tz: String) -> Date {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: tz)
    f.dateFormat = "yyyy-MM-dd HH:mm"; return f.date(from: s)!
}
let gspcCharts = try loadCharts("GSPC"), twiiCharts = try loadCharts("TWII")
func quote(_ id: String, _ day: ChartSeries, _ open: String, _ close: String, _ tz: String) -> IndexQuote {
    IndexQuote(id: id, price: day.points.last!.price, previousClose: day.baseline, time: day.points.last!.time,
               session: Session(start: local(open, tz), end: local(close, tz)), source: .yahoo, intraday: day.points)
}
let spxQuote = quote("SPX", gspcCharts[.intraday]!, "2026-10-08 09:30", "2026-10-08 16:00", "America/New_York")
let twQuote = quote("TWII", twiiCharts[.intraday]!, "2026-10-08 09:00", "2026-10-08 13:30", "Asia/Taipei")
let noNetwork: @Sendable (ChartPeriod, Bool) async throws -> ChartSeries = { _, _ in throw URLError(.cancelled) }

func fxPerUSD(_ code: String) throws -> [ChartPeriod: ChartSeries] {
    var out: [ChartPeriod: ChartSeries] = [:]
    for p in ChartPeriod.fxPeriods {
        let s = try YahooChartParser.parse(Data(contentsOf: fixtures.appendingPathComponent("fxk_\(code)_\(fileOf[p]!).json")), period: p, fetchedAt: chartNow)
        out[p] = FXCross.perUSD(s, pair: USDPair.pair(for: code)!)
    }
    return out
}
let perUSD = ["CNY": try fxPerUSD("CNY"), "JPY": try fxPerUSD("JPY"), "TWD": try fxPerUSD("TWD")]
func fxCharts(_ pair: FXPairSpec) -> [ChartPeriod: ChartSeries] {
    var out: [ChartPeriod: ChartSeries] = [:]
    for p in ChartPeriod.fxPeriods {
        out[p] = FXCross.series(pair, perUSD: perUSD.compactMapValues { $0[p] })
    }
    return out
}

await MainActor.run {
    let spx = IndexSpec.spec("SPX")!, tw = IndexSpec.spec("TWII")!
    for p in ChartPeriod.indexPeriods {
        render("detail-spx-\(p.rawValue)", IndexDetailView(spec: spx, quote: spxQuote, now: chartNow, upIsRed: true, initialPeriod: p,
                                                           preloaded: gspcCharts, load: noNetwork, onOpenExternal: {}), scheme: .light)
    }
    let total = gspcCharts[.daily]!.points.count
    render("detail-spx-daily-hover", IndexDetailView(spec: spx, quote: spxQuote, now: chartNow, upIsRed: true, initialPeriod: .daily,
                                                     preloaded: gspcCharts, initialHover: total - 8, load: noNetwork, onOpenExternal: {}), scheme: .light)
    // 往前翻、缩小以后的样子：一屏 150 根，最右边是 2020 年 4 月前后
    render("detail-spx-daily-panned", IndexDetailView(spec: spx, quote: spxQuote, now: chartNow, upIsRed: true, initialPeriod: .daily,
                                                      preloaded: gspcCharts, initialViewport: KLineViewport(count: 150, right: 900),
                                                      load: noNetwork, onOpenExternal: {}), scheme: .light)
    render("detail-spx-intraday-hover", IndexDetailView(spec: spx, quote: spxQuote, now: chartNow, upIsRed: true, initialPeriod: .intraday,
                                                        preloaded: gspcCharts, initialHover: 100, load: noNetwork, onOpenExternal: {}), scheme: .light)
    // 台湾加权日K：Yahoo 还没补 10/8，最右一根用当天分时补出来
    render("detail-twii-daily-dark", IndexDetailView(spec: tw, quote: twQuote, now: chartNow, upIsRed: true, initialPeriod: .daily,
                                                     preloaded: twiiCharts, initialHover: twiiCharts[.daily]!.points.count,
                                                     load: noNetwork, onOpenExternal: {}), scheme: .dark)
    render("detail-twii-monthly-greenup", IndexDetailView(spec: tw, quote: twQuote, now: chartNow, upIsRed: false, initialPeriod: .monthly,
                                                          preloaded: twiiCharts, initialViewport: KLineViewport(count: 120),
                                                          load: noNetwork, onOpenExternal: {}), scheme: .light)
    render("detail-loading", IndexDetailView(spec: spx, quote: spxQuote, now: chartNow, upIsRed: true, load: noNetwork), scheme: .light)

    let jpyCny = FXPairSpec(from: "JPY", to: "CNY", unit: 100), cnyTwd = FXPairSpec(from: "CNY", to: "TWD"), usdTwd = FXPairSpec(from: "USD", to: "TWD")
    render("fx-jpycny-daily", FXDetailView(pair: jpyCny, upIsRed: true, initialPeriod: .daily, preloaded: fxCharts(jpyCny),
                                           initialHover: fxCharts(jpyCny)[.daily]!.points.count - 2, load: noNetwork, onOpenExternal: {}), scheme: .light)
    render("fx-cnytwd-weekly-dark", FXDetailView(pair: cnyTwd, upIsRed: true, initialPeriod: .weekly, preloaded: fxCharts(cnyTwd),
                                                 initialViewport: KLineViewport(count: 104), load: noNetwork, onOpenExternal: {}), scheme: .dark)
    render("fx-usdtwd-monthly", FXDetailView(pair: usdTwd, upIsRed: true, initialPeriod: .monthly, preloaded: fxCharts(usdTwd),
                                             initialViewport: KLineViewport(count: 250), load: noNetwork, onOpenExternal: {}), scheme: .light)
}
