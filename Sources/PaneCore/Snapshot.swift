import Foundation

public struct PaneSettings: Codable, Sendable, Equatable {
    /// true = 红涨绿跌
    public var upIsRed: Bool
    public init(upIsRed: Bool = true) { self.upIsRed = upIsRed }
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
    public static func fxDue(_ fx: FXSnapshot?, now: Date) -> Bool {
        guard let fx else { return true }
        let outdated = fx.expectedDate != FXCalendar.lastCompletedDay(asOf: now) || fx.isStale || !fx.missing.isEmpty
        return outdated && now.timeIntervalSince(fx.fetchedAt) >= 900
    }
}
