import SwiftUI

/// 账号页最上面：这个账号的 QingTeng Studio 账户卡（`IdCard`），卡的下沿渐渐淡进页面背景，不是硬生生的一条边。
///
/// 淡出从 UID 下面开始（卡高的 83% 处），越往下越快（不透明度 1 − t³），到卡的下沿完全透明；卡下面的投影也一起淡掉，
/// 两侧和上面的投影留着。用的是遮罩，不是盖一层页面颜色，所以深色、浅色模式和任何背景都一样。
struct AccountCardHeader: View {

    /// UID；还没读到时卡上是短横。
    let uid: Int?

    /// 淡出从卡高的这个比例开始（UID 的字在 84%～90% 之间，这里开始时几乎还不透明）。
    static let fadeStart: CGFloat = 0.83

    /// 遮罩往卡外多出的边（留住上面和两侧的投影）。
    private static let overflow: CGFloat = 48

    /// 淡出段的色标：不透明度 1 − t³。
    static let fadeStops: [Gradient.Stop] = (0...12).map { i in
        let t = CGFloat(i) / 12
        return Gradient.Stop(color: .black.opacity(1 - t * t * t), location: t)
    }

    var body: some View {
        IdCard(uid: uid)
            .mask {
                GeometryReader { proxy in
                    let height = proxy.size.height
                    let solid = height * Self.fadeStart
                    VStack(spacing: 0) {
                        Rectangle().frame(height: Self.overflow + solid)
                        LinearGradient(stops: Self.fadeStops, startPoint: .top, endPoint: .bottom)
                            .frame(height: height - solid)
                        Spacer(minLength: 0)
                    }
                    .frame(width: proxy.size.width + 2 * Self.overflow, height: height + 2 * Self.overflow, alignment: .top)
                    .offset(x: -Self.overflow, y: -Self.overflow)
                }
            }
    }
}
