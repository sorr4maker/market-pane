import Foundation

public struct PaneSettings: Codable, Sendable, Equatable {
    /// true = 红涨绿跌
    public var upIsRed: Bool
    /// 面板上显示哪些指数、币种和基准表（用户在「编辑内容」里改）
    public var content: PaneContent
    public init(upIsRed: Bool = true, content: PaneContent = .standard) { self.upIsRed = upIsRed; self.content = content }

    private enum CodingKeys: String, CodingKey { case upIsRed, content }
    /// 旧版本存的快照没有 content，按默认内容读
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        upIsRed = try c.decodeIfPresent(Bool.self, forKey: .upIsRed) ?? true
        content = try c.decodeIfPresent(PaneContent.self, forKey: .content) ?? .standard
    }
}

/// 面板显示的内容。顺序就是显示顺序（指数在各自地区卡片里按这个顺序排）。
public struct PaneContent: Codable, Sendable, Equatable {
    public var indices: [IndexSpec]
    /// 汇率表里出现的币种（代码，如 "JPY"），也是每张表里行的顺序
    public var currencies: [String]
    /// 哪些币种各有一张表，也是表的顺序。美元表是「1 美元 = ? 外币」，其余是「? 外币 = ? 本币」
    public var baseTables: [String]

    public init(indices: [IndexSpec], currencies: [String], baseTables: [String]) {
        self.indices = indices; self.currencies = currencies; self.baseTables = baseTables
    }

    /// 用户最早定的：12 个指数；中日美欧台港；人民币、新台币、美元三张表
    public static let standard = PaneContent(indices: IndexSpec.all, currencies: ["CNY", "JPY", "USD", "EUR", "TWD", "HKD"],
                                             baseTables: ["CNY", "TWD", "USD"])
}

/// 面板上显示的全部数据，存在磁盘上，App 重启后马上能显示上次的内容。
public struct PaneSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var indices: IndexBoard?
    public var fx: FXSnapshot?
    public var settings: PaneSettings
    public init(generatedAt: Date, indices: IndexBoard? = nil, fx: FXSnapshot? = nil, settings: PaneSettings = .init()) {
        self.generatedAt = generatedAt; self.indices = indices; self.fx = fx; self.settings = settings
    }
}

public struct SnapshotStore: Sendable {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func `default`() -> SnapshotStore {
        SnapshotStore(fileURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarketPane", isDirectory: true).appendingPathComponent("snapshot.json"))
    }

    public func save(_ s: PaneSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(s).write(to: fileURL, options: .atomic)
    }

    public func load() -> PaneSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(PaneSnapshot.self, from: data)
    }
}

public enum RefreshPolicy {
    /// 有市场在交易：约每分钟抓一次指数；都休市：5 分钟一次（为了及时发现开盘）。
    public static func indicesDue(_ board: IndexBoard?, now: Date) -> Bool {
        guard let board else { return true }
        let age = now.timeIntervalSince(board.fetchedAt)
        return board.anyTrading(at: now) ? age >= 55 : age >= 300
    }

    /// 汇率是「前一天」的收盘：换日了、或数据落后/缺币种时才抓；失败后最多每 15 分钟重试。
    /// `codes`：用户选的币种（刚加了新币种时它会出现在 missing 里，下一轮就去抓）
    public static func fxDue(_ fx: FXSnapshot?, now: Date, codes: [String] = PaneContent.standard.currencies) -> Bool {
        guard let fx else { return true }
        let outdated = fx.expectedDate != FXCalendar.lastCompletedDay(asOf: now) || fx.isStale || !fx.missing(in: codes).isEmpty
        return outdated && now.timeIntervalSince(fx.fetchedAt) >= 900
    }
}
