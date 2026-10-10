import SwiftUI
import PaneCore

/// 「编辑内容」窗口里的界面：指数、汇率两页。
/// 不自己存状态：`content` 是当前内容，每次改动都通过 `edit` 在最新内容上做（自填代码要等网络，回来时内容可能已经变了）。
public struct ContentEditorView: View {
    let content: PaneContent
    let edit: (_ change: (inout PaneContent) -> Void) -> Void
    let probe: (_ symbol: String, _ name: String?) async throws -> IndexSpec
    @State private var page: Page
    @State private var confirmReset = false

    enum Page: String, Hashable { case indices = "指数", currencies = "汇率" }

    public init(content: PaneContent, initialPage: Int = 0,
                edit: @escaping (_ change: (inout PaneContent) -> Void) -> Void,
                probe: @escaping (_ symbol: String, _ name: String?) async throws -> IndexSpec) {
        self.content = content; self.edit = edit; self.probe = probe
        _page = State(initialValue: initialPage == 1 ? .currencies : .indices)
    }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("指数").tag(Page.indices)
                Text("汇率").tag(Page.currencies)
            }
            .pickerStyle(.segmented).labelsHidden()
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            // 两页一直都在，切换时输入框里写了一半的内容、搜索词不会丢
            ZStack {
                IndexEditorPage(content: content, edit: edit, probe: probe)
                    .opacity(page == .indices ? 1 : 0).allowsHitTesting(page == .indices).accessibilityHidden(page != .indices)
                CurrencyEditorPage(content: content, edit: edit)
                    .opacity(page == .currencies ? 1 : 0).allowsHitTesting(page == .currencies).accessibilityHidden(page != .currencies)
            }

            Divider()
            HStack {
                Text("改动立即生效").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("恢复默认…") { confirmReset = true }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .confirmationDialog("恢复默认内容？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) { edit { $0 = .standard } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("指数回到最初的 12 个，汇率回到中日美欧台港和三张表（人民币、新台币、美元）。")
        }
    }
}

// MARK: 指数页

struct IndexEditorPage: View {
    let content: PaneContent
    let edit: (_ change: (inout PaneContent) -> Void) -> Void
    let probe: (_ symbol: String, _ name: String?) async throws -> IndexSpec
    @State private var search = ""
    @State private var symbol = ""
    @State private var name = ""
    @State private var probing = false
    @State private var probeError: String?

    var body: some View {
        List {
            Section {
                ForEach(content.indices) { spec in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(spec.name)
                            Text("\(spec.yahooSymbol) · \(spec.region.rawValue)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button { remove(spec) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.borderless)
                            .disabled(content.indices.count <= 1)
                            .help(content.indices.count <= 1 ? "至少保留 1 个指数" : "从面板上去掉")
                    }
                }
                .onMove { from, to in edit { $0.indices.move(fromOffsets: from, toOffset: to) } }
            } header: {
                Text("已选指数（\(content.indices.count) 个，拖动调整顺序）")
            } footer: {
                Text("面板上按地区分成亚太、欧洲、美洲三张卡片，同一地区里按这里的顺序排。").font(.system(size: 11))
            }

            Section("从常用清单添加") {
                TextField("搜索中文名或代码", text: $search).textFieldStyle(.roundedBorder)
            }
            let groups = catalogGroups
            ForEach(groups, id: \.0) { region, specs in
                Section(region.rawValue) {
                    ForEach(specs) { spec in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(spec.name)
                                Text(spec.yahooSymbol).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button { edit { $0.indices.append(spec) } } label: {
                                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                            }
                            .buttonStyle(.borderless).help("加到面板")
                        }
                    }
                }
            }
            if groups.isEmpty {
                Text(search.isEmpty ? "常用清单里的指数都已经在面板上了。" : "清单里没有匹配的指数，可以在下面自填代码。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    TextField("Yahoo 代码，如 ^HSI", text: $symbol).textFieldStyle(.roundedBorder).onSubmit(addCustom)
                    TextField("名字（可选）", text: $name).textFieldStyle(.roundedBorder).onSubmit(addCustom)
                    if probing { ProgressView().controlSize(.small) }
                    Button("添加", action: addCustom)
                        .disabled(probing || symbol.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let probeError {
                    Text(probeError).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("自填代码")
            } footer: {
                Text("填 Yahoo Finance 的指数代码（一般以 ^ 开头）。会先试抓一次，抓得到才加；只能加指数。").font(.system(size: 11))
            }
        }
        .listStyle(.inset)
    }

    /// 常用清单里还没选的，按地区分组；有搜索词时按中文名、代码过滤
    private var catalogGroups: [(Region, [IndexSpec])] {
        let chosen = Set(content.indices.map(\.yahooSymbol))
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let left = IndexCatalog.all.filter { spec in
            !chosen.contains(spec.yahooSymbol)
                && (q.isEmpty || spec.name.lowercased().contains(q) || spec.yahooSymbol.lowercased().contains(q) || spec.id.lowercased().contains(q))
        }
        return Region.allCases.compactMap { r in
            let list = left.filter { $0.region == r }
            return list.isEmpty ? nil : (r, list)
        }
    }

    private func remove(_ spec: IndexSpec) {
        edit { c in
            guard c.indices.count > 1 else { return }
            c.indices.removeAll { $0.id == spec.id }
        }
    }

    private func addCustom() {
        let code = symbol.trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, !probing else { return }
        if content.indices.contains(where: { $0.yahooSymbol.caseInsensitiveCompare(code) == .orderedSame }) {
            probeError = "已经在面板上了"
            return
        }
        probeError = nil
        probing = true
        let label = name.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            defer { probing = false }
            do {
                let spec = try await probe(code, label.isEmpty ? nil : label)
                var exists = false
                edit { c in
                    if c.indices.contains(where: { $0.yahooSymbol == spec.yahooSymbol || $0.id == spec.id }) { exists = true }
                    else { c.indices.append(spec) }
                }
                if exists { probeError = "已经在面板上了" } else { symbol = ""; name = "" }
            } catch {
                probeError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

// MARK: 汇率页

struct CurrencyEditorPage: View {
    let content: PaneContent
    let edit: (_ change: (inout PaneContent) -> Void) -> Void

    var body: some View {
        List {
            Section {
                ForEach(content.currencies, id: \.self) { code in
                    let isTable = content.baseTables.contains(code)
                    let lastTable = isTable && content.baseTables.count <= 1
                    HStack(spacing: 8) {
                        Text(Currency.named(code).name)
                        Text(code).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text("单独一张表").font(.system(size: 12)).foregroundStyle(.secondary)
                        Toggle("单独一张表", isOn: Binding(get: { isTable }, set: { setTable(code, $0) }))
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .disabled(lastTable)
                            .help(lastTable ? "至少保留 1 张表" : "以\(Currency.named(code).name)为基准单独列一张表")
                        Button { remove(code) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.borderless)
                            .disabled(content.currencies.count <= 2 || lastTable)
                            .help(content.currencies.count <= 2 ? "至少保留 2 个币种" : lastTable ? "这是唯一的一张表，先给别的币种开一张表" : "从面板上去掉")
                    }
                }
                .onMove { from, to in
                    edit { c in
                        c.currencies.move(fromOffsets: from, toOffset: to)
                        Self.syncTables(&c)
                    }
                }
            } header: {
                Text("已选币种（\(content.currencies.count) 个，拖动调整顺序）")
            } footer: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("表的顺序和币种顺序一致；表里的行也按这个顺序。至少 2 个币种、1 张表。")
                    Text("美元表是「1 美元 = ? 外币」，其余表是「? 外币 = ? 本币」。")
                }
                .font(.system(size: 11))
            }

            Section("添加币种") {
                let left = Currency.all.filter { !content.currencies.contains($0.code) }
                if left.isEmpty {
                    Text("可选的币种都已经加上了。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(left, id: \.code) { cur in
                    HStack(spacing: 8) {
                        Text(cur.name)
                        Text(cur.code).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button { edit { $0.currencies.append(cur.code) } } label: {
                            Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.borderless).help("加到面板")
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    /// 表的顺序 = 币种顺序，且只能是已选的币种
    private static func syncTables(_ c: inout PaneContent) {
        let tables = Set(c.baseTables)
        c.baseTables = c.currencies.filter { tables.contains($0) }
    }

    private func setTable(_ code: String, _ on: Bool) {
        edit { c in
            if on { if !c.baseTables.contains(code) { c.baseTables.append(code) } }
            else if c.baseTables.count > 1 { c.baseTables.removeAll { $0 == code } }
            Self.syncTables(&c)
        }
    }

    private func remove(_ code: String) {
        edit { c in
            guard c.currencies.count > 2 else { return }
            let tables = c.baseTables.filter { $0 != code }
            guard !tables.isEmpty else { return }   // 不能把最后一张表删没
            c.currencies.removeAll { $0 == code }
            c.baseTables = tables
            Self.syncTables(&c)
        }
    }
}
