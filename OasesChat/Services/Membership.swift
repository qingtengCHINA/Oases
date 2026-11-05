import Foundation
import MetalFxKit
import StoreKit
import SwiftUI

/// StoreKit 2 product identifiers. Create these as auto-renewable subscriptions
/// in App Store Connect, in one subscription group named "Oases Membership".
///
/// - `dev.oases.chat.ios.membership.lite.monthly`
/// - `dev.oases.chat.ios.membership.pro.monthly`
/// - `dev.oases.chat.ios.membership.ultra.monthly`
enum MembershipTier: Int, Comparable, CaseIterable, Identifiable {
    case free = 0
    case lite = 1
    case pro = 2
    case ultra = 3

    var id: Int { rawValue }

    static func < (lhs: MembershipTier, rhs: MembershipTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .free: return "Oases Free"
        case .lite: return "Oases Lite"
        case .pro: return "Oases Pro"
        case .ultra: return "Oases Ultra"
        }
    }

    var shortName: String {
        switch self {
        case .free: return SettingsCopy.t("免费版", "Free")
        case .lite: return "Lite"
        case .pro: return "Pro"
        case .ultra: return "Ultra"
        }
    }

    var productID: String? {
        switch self {
        case .free: return nil
        case .lite: return "dev.oases.chat.ios.membership.lite.monthly"
        case .pro: return "dev.oases.chat.ios.membership.pro.monthly"
        case .ultra: return "dev.oases.chat.ios.membership.ultra.monthly"
        }
    }

    static func tier(for productID: String) -> MembershipTier? {
        allCases.first { $0.productID == productID }
    }

    static let paidProductIDs = ["dev.oases.chat.ios.membership.lite.monthly",
                                 "dev.oases.chat.ios.membership.pro.monthly",
                                 "dev.oases.chat.ios.membership.ultra.monthly"]
}

struct MembershipDenial: Equatable {
    var reason: String
    var suggested: MembershipTier
}

@MainActor
final class MembershipCenter: ObservableObject {
    static let shared = MembershipCenter()

    @Published private(set) var tier: MembershipTier = .free
    @Published private(set) var products: [Product] = []
    /// 首轮商品拉取是否已结束（无论成败）。用来区分"还在加载"和"加载失败"。
    @Published private(set) var productsLoaded = false
    /// 计数器每次累加时 +1，驱动用量页实时刷新剩余额度。
    @Published private(set) var usageRevision = 0
    @Published var suggestedTier: MembershipTier = .pro
    @Published var pendingReason: String?
    @Published var purchaseError: String?

    private var updates: Task<Void, Never>?
    private var didStart = false

    private init() {
        if let raw = UserDefaults.standard.object(forKey: Self.cacheKey) as? Int,
           let cached = MembershipTier(rawValue: raw) {
            tier = cached
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        updates = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if case .verified(let transaction) = update {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        Task { await self.reload() }
    }

    func reload() async {
        await refreshEntitlements()
        do {
            products = try await Product.products(for: MembershipTier.paidProductIDs)
        } catch {
            products = []
        }
        productsLoaded = true
    }

    func product(for tier: MembershipTier) -> Product? {
        guard let id = tier.productID else { return nil }
        return products.first { $0.id == id }
    }

    /// StoreKit 2 的真实价格；商品还没拉到（或拉取失败）时为 nil，UI 显示加载态。
    func priceLabel(for tier: MembershipTier) -> String? {
        product(for: tier)?.displayPrice
    }

    func purchase(_ tier: MembershipTier) async {
        purchaseError = nil
        guard let product = product(for: tier) else {
            purchaseError = SettingsCopy.t(
                "暂时无法获取这个订阅的信息，请检查网络后重试。",
                "Couldn't load this subscription. Check your connection and try again."
            )
            return
        }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                if case .verified(let transaction) = verification {
                    await transaction.finish()
                    await refreshEntitlements()
                } else {
                    purchaseError = SettingsCopy.t("购买结果无法验证。", "The purchase couldn't be verified.")
                }
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    func restore() async {
        purchaseError = nil
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            if tier == .free {
                purchaseError = SettingsCopy.t("没有找到可恢复的订阅。", "No subscription to restore was found.")
            }
        } catch {
            purchaseError = error.localizedDescription
        }
    }

    #if DEBUG
    /// Tests only: pretend the user is on `tier`.
    func overrideTierForTesting(_ tier: MembershipTier) {
        self.tier = tier
    }

    /// Tests only: today's counter for a quota bucket ("text", "image", "ogent").
    func usedTodayForTesting(_ bucket: String) -> Int {
        count(bucket)
    }
    #endif

    func present(_ denial: MembershipDenial) {
        suggestedTier = denial.suggested
        pendingReason = denial.reason
        NotificationCenter.default.post(name: .membershipPaywall, object: nil)
    }

    func authorize(category: Models.Category, modelId: String) -> MembershipDenial? {
        switch category {
        case .audio:
            return nil
        case .image:
            return authorizeImage()
        case .text:
            return authorizeText(modelId: modelId)
        case .project:
            return authorizeOgent(ownModel: Self.isOwnModel(modelId), modelId: Self.catalogId(modelId))
        }
    }

    func commit(category: Models.Category, modelId: String) {
        switch category {
        case .audio:
            break
        case .image:
            if tier == .free || tier == .lite { bump("image") }
        case .text:
            if tier == .free, !Self.isPromoFreeBuiltin(modelId) { bump("text") }
        case .project:
            if !Self.isOwnModel(modelId), !Self.isPromoFreeBuiltin(modelId) { bump("ogent") }
        }
    }

    func authorizeOgent(ownModel: Bool, modelId: String) -> MembershipDenial? {
        if ownModel { return nil }
        // 限免模型不受会员机制限制。
        if Models.isPromoFree(modelId) { return nil }
        if Models.option(for: modelId)?.isBeta == true, tier < .pro {
            return MembershipDenial(
                reason: SettingsCopy.t("尝鲜模型需要 Oases Pro 及以上。", "Beta models require Oases Pro or above."),
                suggested: .pro
            )
        }
        guard let cap = ogentCap else { return nil }
        if count("ogent") >= cap {
            return MembershipDenial(
                reason: String(format: SettingsCopy.t(
                    "今天的 Ogent 内置模型对话次数已用完（%d 次）。自配模型不计入这次数。",
                    "You've used all %d built-in Ogent conversations today. Your own models don't count toward this limit."
                ), cap),
                suggested: nextTier
            )
        }
        return nil
    }

    func commitOgent(ownModel: Bool, modelId: String? = nil) {
        if ownModel { return }
        if let modelId, Models.isPromoFree(modelId) { return }
        bump("ogent")
    }

    // MARK: - Rules

    private var ogentCap: Int? {
        switch tier {
        case .free: return 3
        case .lite: return 20
        case .pro: return 50
        case .ultra: return nil
        }
    }

    private var nextTier: MembershipTier {
        switch tier {
        case .free: return .lite
        case .lite: return .pro
        case .pro, .ultra: return .ultra
        }
    }

    private func authorizeText(modelId: String) -> MembershipDenial? {
        let id = Self.catalogId(modelId)
        // 限免模型不受会员机制限制（用户自配的同名模型不算）。
        if Self.isPromoFreeBuiltin(modelId) { return nil }
        if Models.option(for: id)?.isBeta == true, tier < .pro {
            return MembershipDenial(
                reason: SettingsCopy.t("尝鲜模型需要 Oases Pro 及以上。", "Beta models require Oases Pro or above."),
                suggested: .pro
            )
        }
        guard tier == .free else { return nil }
        if Self.isOwnModel(modelId) || id != Models.defaultChat {
            return MembershipDenial(
                reason: SettingsCopy.t("免费版文本只能使用 Oases Fast。", "Free plan text chat works with Oases Fast only."),
                suggested: .lite
            )
        }
        if count("text") >= 20 {
            return MembershipDenial(
                reason: String(format: SettingsCopy.t(
                    "今天的免费文本次数已用完（%d 次）。",
                    "You've used all %d free text messages today."
                ), 20),
                suggested: .lite
            )
        }
        return nil
    }

    private func authorizeImage() -> MembershipDenial? {
        switch tier {
        case .free where count("image") >= 5:
            return MembershipDenial(
                reason: String(format: SettingsCopy.t(
                    "今天的免费图像次数已用完（%d 次）。",
                    "You've used all %d free image generations today."
                ), 5),
                suggested: .lite
            )
        case .lite where count("image") >= 30:
            return MembershipDenial(
                reason: String(format: SettingsCopy.t(
                    "今天的图像次数已用完（%d 次）。",
                    "You've used all %d image generations today."
                ), 30),
                suggested: .pro
            )
        default:
            return nil
        }
    }

    /// A built-in (not user-configured) limited-time free model.
    private static func isPromoFreeBuiltin(_ modelId: String) -> Bool {
        !isOwnModel(modelId) && Models.isPromoFree(catalogId(modelId))
    }

    private static func catalogId(_ modelId: String) -> String {
        guard let entryId = ProviderChatRouting.entryId(from: modelId),
              let entry = ProviderConfigStore.shared.entry(for: entryId) else { return modelId }
        return entry.model.id
    }

    private static func isOwnModel(_ modelId: String) -> Bool {
        guard let entryId = ProviderChatRouting.entryId(from: modelId),
              let entry = ProviderConfigStore.shared.entry(for: entryId) else { return false }
        return !OasesBuiltinProvider.owns(entry.providerInstanceId)
    }

    private func refreshEntitlements() async {
        var best = MembershipTier.free
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard transaction.revocationDate == nil else { continue }
            guard let match = MembershipTier.tier(for: transaction.productID) else { continue }
            if match > best { best = match }
        }
        tier = best
        UserDefaults.standard.set(best.rawValue, forKey: Self.cacheKey)
    }

    private static let cacheKey = "membership.tier.cache"

    private func count(_ bucket: String) -> Int {
        UserDefaults.standard.integer(forKey: counterKey(bucket))
    }

    private func bump(_ bucket: String) {
        let key = counterKey(bucket)
        UserDefaults.standard.set(count(bucket) + 1, forKey: key)
        usageRevision += 1
    }

    // MARK: - Quotas

    struct QuotaItem: Identifiable {
        let id: String
        let title: String
        let used: Int
        /// nil = 不限量
        let limit: Int?

        var remaining: Int? { limit.map { max(0, $0 - used) } }
    }

    /// 当前等级今天的额度快照（文本 / 图像 / Ogent 内置模型），
    /// 与 authorize/commit 用的是同一套计数器和上限，天然实时。
    var quotas: [QuotaItem] {
        let textLimit: Int? = tier == .free ? 20 : nil
        let imageLimit: Int? = {
            switch tier {
            case .free: return 5
            case .lite: return 30
            case .pro, .ultra: return nil
            }
        }()
        return [
            QuotaItem(id: "text", title: SettingsCopy.t("文本 · Oases Fast", "Text · Oases Fast"),
                      used: count("text"), limit: textLimit),
            QuotaItem(id: "image", title: SettingsCopy.t("图像生成", "Image generation"),
                      used: count("image"), limit: imageLimit),
            QuotaItem(id: "ogent", title: SettingsCopy.t("Ogent 内置模型", "Ogent · built-in models"),
                      used: count("ogent"), limit: ogentCap),
        ]
    }

    private func counterKey(_ bucket: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "membership.\(bucket).\(formatter.string(from: Date()))"
    }
}

// MARK: - Paywall

/// 订阅页全面走设计系统：OasesColor token 随主题（深浅色）适配，
/// 文案走 SettingsCopy 跟随设置里选择的显示语言，极光背景与主页空状态一致。
struct MembershipPaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var membership = MembershipCenter.shared
    @State private var plan: MembershipTier = .pro
    @State private var buying = false
    @State private var expandedNoteRow: String?

    private var accent: Color { OasesColor.accent }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(spacing: OasesSpacing.lg) {
                        hero
                        if let reason = membership.pendingReason {
                            reasonBanner(reason)
                        }
                        planPicker
                        benefits
                        if let error = membership.purchaseError {
                            Text(error)
                                .font(.oasesCaption())
                                .foregroundStyle(OasesColor.destructive)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, OasesSpacing.md)
                    .padding(.bottom, OasesSpacing.lg)
                }
                bottomBar
            }
        }
        .onAppear {
            plan = membership.suggestedTier == .free ? .pro : membership.suggestedTier
            membership.start()
        }
    }

    // MARK: Chrome

    private var background: some View {
        ZStack {
            OasesColor.background.ignoresSafeArea()
            AuroraBackground(tint: accent).opacity(0.32)
            LinearGradient(
                colors: [OasesColor.background.opacity(0.25), OasesColor.background],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OasesColor.foreground.opacity(0.75))
                    .frame(width: 32, height: 32)
                    .background(OasesColor.foreground.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(SettingsCopy.t("关闭", "Close"))
            Spacer()
        }
        .padding(.horizontal, OasesSpacing.md)
        .padding(.vertical, OasesSpacing.xs)
    }

    private var hero: some View {
        VStack(spacing: OasesSpacing.sm) {
            // 品牌位：双池标志本身，不带图标底板，跟随前景色。
            OasesMark(size: 64)
                .padding(.bottom, OasesSpacing.xxs)
            MetalText(plan.title, font: .oasesTitle(), color: OasesColor.foreground, preset: .chromatic)
            Text(SettingsCopy.t("解锁全部模型与更高额度。", "Unlock every model with higher limits."))
                .font(.oasesCallout())
                .foregroundStyle(OasesColor.mutedForeground)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, OasesSpacing.xs)
    }

    private func reasonBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: OasesSpacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .padding(.top, 1)
            Text(reason)
                .font(.oasesCaption())
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(accent)
        .padding(.horizontal, OasesSpacing.sm)
        .padding(.vertical, OasesSpacing.sm - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous))
    }

    // MARK: Plan picker

    private var planPicker: some View {
        HStack(spacing: OasesSpacing.sm) {
            ForEach([MembershipTier.lite, .pro, .ultra]) { item in
                planCard(item)
            }
        }
    }

    private func planCard(_ item: MembershipTier) -> some View {
        let selected = plan == item
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { plan = item }
        } label: {
            VStack(spacing: OasesSpacing.xxs) {
                Text(item.shortName)
                    .font(.oasesCaptionBold())
                if let price = membership.priceLabel(for: item) {
                    Text(price)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                } else {
                    // 真实价格从 App Store 拉取，到位前显示加载态而不是假价格。
                    ProgressView()
                        .controlSize(.small)
                        .tint(selected ? accent : OasesColor.mutedForeground)
                        .frame(height: 19)
                }
                Text(SettingsCopy.t("每月", "per month"))
                    .font(.oasesFootnote())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
            .foregroundStyle(selected ? accent : OasesColor.foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, OasesSpacing.sm + 2)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
                    .fill(selected ? accent.opacity(0.14) : OasesColor.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
                    .strokeBorder(selected ? accent : OasesColor.border, lineWidth: selected ? 1.6 : 0.8)
            )
            .overlay(alignment: .top) {
                if item == .pro {
                    Text(SettingsCopy.t("最受欢迎", "Most Popular"))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(accent, in: Capsule())
                        .offset(y: -9)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Benefits

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                Text(SettingsCopy.t("会员权益", "Membership Benefits"))
                    .font(.oasesHeadline())
                    .foregroundStyle(OasesColor.foreground)
                Spacer()
                Text(SettingsCopy.t("免费版", "Free"))
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .frame(width: 52)
                Text(plan.shortName)
                    .font(.oasesCaptionBold())
                    .foregroundStyle(accent)
                    .frame(width: 64)
                    .padding(.vertical, 3)
                    .background(accent.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.top, OasesSpacing.md)
            .padding(.bottom, OasesSpacing.xs)

            ForEach(rows) { row in
                VStack(spacing: 0) {
                    HStack {
                        Text(row.title)
                            .font(.oasesCallout())
                            .foregroundStyle(OasesColor.foreground.opacity(0.9))
                        if row.note != nil {
                            Button {
                                withAnimation(.easeOut(duration: 0.18)) {
                                    expandedNoteRow = expandedNoteRow == row.id ? nil : row.id
                                }
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OasesColor.mutedForeground)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(SettingsCopy.t("注释", "Info"))
                        }
                        Spacer(minLength: 4)
                        cell(row.free).frame(width: 52)
                        cell(row.paid).frame(width: 64)
                    }
                    .padding(.horizontal, OasesSpacing.md)
                    .padding(.vertical, OasesSpacing.sm)
                    if expandedNoteRow == row.id, let note = row.note {
                        Text(note)
                            .font(.oasesCaption())
                            .foregroundStyle(OasesColor.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, OasesSpacing.md)
                            .padding(.bottom, OasesSpacing.sm)
                    }
                    if row.id != rows.last?.id {
                        Divider().padding(.leading, OasesSpacing.md)
                    }
                }
            }
        }
        .background(OasesColor.card, in: RoundedRectangle(cornerRadius: OasesRadius.xl, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.xl, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        VStack(spacing: OasesSpacing.sm) {
            if membership.productsLoaded && membership.products.isEmpty {
                // 商品拉取失败（网络/区域等）：给出重试入口，CTA 保持禁用。
                HStack(spacing: 6) {
                    Text(SettingsCopy.t("价格加载失败", "Couldn't load prices"))
                    Button(SettingsCopy.t("重试", "Retry")) {
                        Task { await membership.reload() }
                    }
                    .foregroundStyle(accent)
                }
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
            }
            ctaButton
            Text(SettingsCopy.t("按月订阅，随时取消。", "Billed monthly. Cancel anytime."))
                .font(.oasesFootnote())
                .foregroundStyle(OasesColor.mutedForeground)
            footerLinks
        }
        .padding(.horizontal, OasesSpacing.md)
        .padding(.top, OasesSpacing.xs)
        .padding(.bottom, OasesSpacing.sm)
    }

    /// CTA 只在"价格已从 App Store 拉到、且不是当前/更低方案"时可点。
    private var ctaReady: Bool {
        plan > membership.tier && membership.priceLabel(for: plan) != nil
    }

    private var ctaButton: some View {
        Button {
            Task { await buy() }
        } label: {
            // 液态金属包边：内容内缩 2pt，让 chromatic 金属带沿按钮边缘可见，
            // 整体外尺寸仍保持 52pt 高。
            MetalFx(variant: .button, preset: .chromatic, strength: 0.9,
                    cornerRadius: OasesRadius.lg, innerShadow: true, fill: accent) {
                Group {
                    if buying {
                        ProgressView().tint(.white)
                    } else {
                        Text(buttonTitle)
                            .font(.oasesBodyBold())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52 - 4)
                .background(
                    LinearGradient(
                        colors: [accent, accent.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: OasesRadius.lg - 2, style: .continuous)
                )
                .padding(2)
            }
            .shadow(color: accent.opacity(ctaReady ? 0.35 : 0), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(buying || !ctaReady)
        .opacity(!buying && !ctaReady ? 0.55 : 1)
    }

    /// 服务条款 · 隐私政策 · 恢复购买 · 兑换会员 —— 一行排开。
    private var footerLinks: some View {
        HStack(spacing: OasesSpacing.xs) {
            Link(SettingsCopy.t("服务条款", "Terms"), destination: OasesBrand.termsOfUseURL)
            footerSeparator
            Link(SettingsCopy.t("隐私政策", "Privacy"), destination: OasesBrand.privacyPolicyURL)
            footerSeparator
            Button(SettingsCopy.t("恢复购买", "Restore")) {
                Task { await membership.restore() }
            }
            footerSeparator
            Button(SettingsCopy.t("兑换会员", "Redeem")) {
                UIApplication.shared.open(OasesBrand.appStoreRedeemURL)
            }
        }
        .buttonStyle(.plain)
        .font(.oasesCaption())
        .foregroundStyle(OasesColor.mutedForeground)
        .tint(OasesColor.mutedForeground)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var footerSeparator: some View {
        Text(verbatim: "·")
            .foregroundStyle(OasesColor.mutedForeground.opacity(0.5))
    }

    // MARK: Helpers

    private var buttonTitle: String {
        if membership.tier == plan { return SettingsCopy.t("当前方案", "Current plan") }
        if membership.tier > plan {
            return String(format: SettingsCopy.t("已包含在 %@ 中", "Included in %@"), membership.tier.title)
        }
        guard let price = membership.priceLabel(for: plan) else {
            return SettingsCopy.t("加载中…", "Loading…")
        }
        return String(
            format: SettingsCopy.t("取得 %1$@ · %2$@/月", "Get %1$@ · %2$@/mo"),
            plan.shortName,
            price
        )
    }

    private func buy() async {
        buying = true
        await membership.purchase(plan)
        buying = false
        if membership.tier >= plan { dismiss() }
    }

    private struct BenefitRow: Identifiable {
        let id: String
        let title: String
        let free: BenefitCell
        let paid: BenefitCell
        var note: String? = nil
    }

    private enum BenefitCell {
        case check, dash, text(String)
    }

    private func perDay(_ n: Int) -> BenefitCell {
        .text(String(format: SettingsCopy.t("%d次/天", "%d/day"), n))
    }

    private var rows: [BenefitRow] {
        let imagePaid: BenefitCell = {
            switch plan {
            case .lite: return perDay(30)
            case .pro, .ultra: return .check
            case .free: return .dash
            }
        }()
        let ogentPaid: BenefitCell = {
            switch plan {
            case .lite: return perDay(20)
            case .pro: return perDay(50)
            case .ultra: return .check
            case .free: return .dash
            }
        }()
        return [
            BenefitRow(id: "fast", title: SettingsCopy.t("文本 · Oases Fast", "Text · Oases Fast"), free: perDay(20), paid: .check),
            BenefitRow(id: "text", title: SettingsCopy.t("文本 · 其他模型", "Text · Other models"), free: .dash, paid: .check),
            BenefitRow(id: "beta", title: SettingsCopy.t("尝鲜模型", "Beta models"), free: .dash,
                       paid: plan >= .pro ? .check : .dash,
                       note: SettingsCopy.t(
                           "尝鲜模型是测试内容，会有不稳定被停用的可能，并且也会随时进行更换和更新。",
                           "Beta models are experimental: they may be unstable or discontinued, and can be swapped or updated at any time."
                       )),
            BenefitRow(id: "audio", title: SettingsCopy.t("音频", "Voice"), free: .check, paid: .check),
            BenefitRow(id: "image", title: SettingsCopy.t("图像生成", "Image generation"), free: perDay(5), paid: imagePaid),
            BenefitRow(id: "own", title: SettingsCopy.t("Ogent 自配模型", "Ogent · your own models"), free: .check, paid: .check),
            BenefitRow(id: "ogent", title: SettingsCopy.t("Ogent 内置模型", "Ogent · built-in models"), free: perDay(3), paid: ogentPaid),
        ]
    }

    @ViewBuilder
    private func cell(_ value: BenefitCell) -> some View {
        switch value {
        case .check:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(accent)
        case .dash:
            Text(verbatim: "–")
                .font(.oasesCallout())
                .foregroundStyle(OasesColor.mutedForeground.opacity(0.5))
        case .text(let string):
            Text(string)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}
