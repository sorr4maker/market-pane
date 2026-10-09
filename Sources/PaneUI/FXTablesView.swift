import SwiftUI
import PaneCore

/// 汇率三张表（人民币 / 新台币 / 美元为基准）。面板拉小时只显示一张，用顶部的切换按钮换；选了哪张会记住。
public struct FXTablesView: View {
    let fx: FXSnapshot?
    let upIsRed: Bool
    /// 点某一行打开那个货币对的 K 线
    let onSelect: ((FXPairSpec) -> Void)?
    @Environment(\.paneStyle) private var st
    @AppStorage("fxTableIndex") private var selected = 0

    public init(fx: FXSnapshot?, upIsRed: Bool, onSelect: ((FXPairSpec) -> Void)? = nil) {
        self.fx = fx; self.upIsRed = upIsRed; self.onSelect = onSelect
    }

    public var body: some View {
        let tables = FXTables.build(fx)
        VStack(alignment: .leading, spacing: st.s(6)) {
            HStack(spacing: st.s(4)) {
                Text("汇率").font(.system(size: st.s(12), weight: .semibold))
                Spacer(minLength: 0)
                Text(fx?.displayDate.map { "\(Fmt.fxDay($0)) 收盘" } ?? "尚未获取")
                    .font(.system(size: st.s(10))).foregroundStyle(.secondary)
            }
            .frame(height: st.s(16))
            if st.fxSingle {
                let i = min(max(selected, 0), tables.count - 1)
                TableSwitcher(titles: tables.map(\.title), selected: i) { selected = $0 }
                table(tables[i], showTitle: false)
            } else {
                ForEach(tables, id: \.title) { table($0, showTitle: true) }
            }
            if let fx, fx.isStale || !fx.missing.isEmpty {
                Text(fx.missing.isEmpty ? "部分汇率落后于 \(Fmt.fxDay(fx.expectedDate))" : "暂缺：\(fx.missing.map { Currency.named($0).name }.joined(separator: "、"))")
                    .font(.system(size: st.s(9))).foregroundStyle(.orange)
            }
        }
    }

    private func table(_ table: FXTableModel, showTitle: Bool) -> some View {
        GroupCard(title: showTitle ? table.title : nil, note: table.subtitle) {
            ForEach(table.rows, id: \.label) { row in
                FXRow(row: row, upIsRed: upIsRed, onSelect: onSelect.map { f in { f(row.pair) } })
            }
        }
    }
}

/// 一张表模式下的切换：人民币 / 新台币 / 美元
struct TableSwitcher: View {
    let titles: [String]
    let selected: Int
    let choose: (Int) -> Void
    @Environment(\.paneStyle) private var st
    var body: some View {
        HStack(spacing: st.s(2)) {
            ForEach(titles.indices, id: \.self) { i in
                Button { choose(i) } label: {
                    Text(titles[i])
                        .font(.system(size: st.s(10), weight: i == selected ? .semibold : .regular))
                        .foregroundStyle(i == selected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity, minHeight: st.s(18))
                        .background(RoundedRectangle(cornerRadius: st.s(5)).fill(Color.primary.opacity(i == selected ? 0.12 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(i == selected ? .isSelected : [])
            }
        }
        .padding(st.s(2))
        .background(RoundedRectangle(cornerRadius: st.s(7)).fill(Color.primary.opacity(0.05)))
    }
}

/// 汇率表的一行。整行可点（有点击回调时），悬停高亮，和指数行一样。
struct FXRow: View {
    let row: FXRowModel
    let upIsRed: Bool
    let onSelect: (() -> Void)?
    @State private var hovering = false
    @Environment(\.paneStyle) private var st

    var body: some View {
        HStack(spacing: st.s(6)) {
            Text(row.label).font(.system(size: st.s(12))).lineLimit(1).frame(width: st.s(70), alignment: .leading)
            Text(Fmt.fx(row.value)).font(.system(size: st.s(12), weight: .medium).monospacedDigit())
                .lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            ChangePill(value: row.changePercent, upIsRed: upIsRed, width: 58, fontSize: 11)
        }
        .frame(height: st.s(18))
        .background(
            RoundedRectangle(cornerRadius: st.s(6), style: .continuous).fill(Color.primary.opacity(hovering && onSelect != nil ? 0.08 : 0))
                .padding(.horizontal, -st.s(5))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onSelect?() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .accessibilityHint(onSelect == nil ? "" : "查看 K 线")
    }
}
