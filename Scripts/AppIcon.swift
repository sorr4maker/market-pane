// App 图标「面板缩影」：蓝紫渐变底 + 一张白卡片，几行指数、红绿走势线和涨跌块。
// 用法：swift Scripts/AppIcon.swift <输出.png>   → 画一张 1024×1024 的 PNG
// 一般不直接跑，用 Scripts/make-icon.sh 一步生成 Resources/AppIcon.icns。改颜色、改形状改这里。
import SwiftUI
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let red = Color(red: 0.93, green: 0.27, blue: 0.27), green = Color(red: 0.16, green: 0.70, blue: 0.40)

/// macOS 图标规格：1024 画布，主体 824、连续圆角 185，下方轻微投影
struct IconBody<Content: View>: View {
    let fill: AnyShapeStyle
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous).fill(fill)
            content()
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.0)], startPoint: .top, endPoint: .center), lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 12)
        .frame(width: 1024, height: 1024)
    }
}

/// 面板缩影 —— 白卡片，一行标题 + 三行指数（名称条、迷你走势、涨跌块），就是行情窗本身的样子
struct PanelIcon: View {
    var body: some View {
        IconBody(fill: AnyShapeStyle(LinearGradient(colors: [Color(red: 0.30, green: 0.52, blue: 0.98), Color(red: 0.42, green: 0.30, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing))) {
            ZStack {
                RoundedRectangle(cornerRadius: 70, style: .continuous).fill(.white.opacity(0.92)).frame(width: 600, height: 560)
                    .shadow(color: .black.opacity(0.25), radius: 20, y: 10)
                VStack(alignment: .leading, spacing: 46) {
                    RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.2)).frame(width: 200, height: 34)
                    ForEach(Array([(true, 0.8), (false, 0.55), (true, 0.7)].enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 28) {
                            RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.75)).frame(width: 150, height: 28)
                            Path { p in
                                let ys: [CGFloat] = row.0 ? [50, 34, 40, 18, 24, 4] : [6, 20, 14, 36, 30, 50]
                                p.move(to: .init(x: 0, y: ys[0])); for (i, y) in ys.enumerated().dropFirst() { p.addLine(to: .init(x: CGFloat(i) * 30, y: y)) }
                            }
                            .stroke(row.0 ? red : green, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round)).frame(width: 150, height: 54)
                            RoundedRectangle(cornerRadius: 12).fill(row.0 ? red : green).frame(width: 110, height: 40)
                        }
                    }
                }
            }
        }
    }
}

MainActor.assumeIsolated {
    let r = ImageRenderer(content: PanelIcon()); r.scale = 1
    guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { print("画图失败"); exit(1) }
    try! png.write(to: out)
}
