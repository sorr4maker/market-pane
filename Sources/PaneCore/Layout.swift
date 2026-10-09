import Foundation

/// 面板自适应：窗口变小时字号先跟着缩（最小 0.75 倍），再小就整块整块地收起内容（见 PaneUI 的 PaneStyle.tiers），
/// 每一档内容在选中的倍数下一定完整放得下，不会有哪一块只露一半。拉大时整体放大，最多 1.8 倍。
public enum PaneScale {
    /// 字号最小缩到 1 倍的 75%（最小的 9pt 字约 6.8pt）；再小就换更紧凑的一档
    public static let minScale = 0.75
    public static let maxScale = 1.8

    public typealias Size = (width: Double, height: Double)

    /// 某一档放进窗口，宽、高都放得下的最大倍数（取较小的），不超过 maxScale
    public static func fit(width: Double, height: Double, tier: Size) -> Double {
        guard tier.width > 0, tier.height > 0, width > 0, height > 0 else { return 1 }
        return min(width / tier.width, height / tier.height, maxScale)
    }

    /// 按窗口大小挑档位：从最完整的一档往下，第一档的倍数不小于 minScale 就用它；都不行就用最后一档（只能再缩字号）。
    /// `tiers` 是每一档在 1 倍时需要的大小，从完整到紧凑。
    public static func choose(width: Double, height: Double, tiers: [Size]) -> (tier: Int, scale: Double) {
        guard let last = tiers.indices.last else { return (0, 1) }
        for i in tiers.indices {
            let k = fit(width: width, height: height, tier: tiers[i])
            if k >= minScale || i == last { return (i, k) }
        }
        return (last, 1)
    }

    /// 能拉到多大：完整一档放大到 maxScale 倍，且不超过屏幕可用区域
    public static func maxSize(full: Size, screenWidth: Double, screenHeight: Double) -> Size {
        (min(full.width * maxScale, screenWidth), min(full.height * maxScale, screenHeight))
    }

    /// 能缩到多小：最紧凑一档缩到 minScale 倍
    public static func minSize(compact: Size) -> Size {
        (compact.width * minScale, compact.height * minScale)
    }
}
