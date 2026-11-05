//
//  SkillStoreView.swift
//  OasesChatApp
//
//  Curated skill store: browse categorized featured skills and install
//  them with one tap through the existing GitHub import pipeline
//  (SkillStore.importFromGitHub). The catalog is decoupled from the view —
//  `CuratedSkillCatalogLoading` is the seam where a remote-fetching loader
//  can replace the bundle-shipped JSON later without touching this file.
//

import SwiftUI

// MARK: - Catalog Models

/// One featured skill entry in CuratedSkills.json.
struct CuratedSkill: Codable, Identifiable, Hashable {
    /// Matches the installed skill id (slug of the SKILL.md frontmatter
    /// name) so "already installed" detection is a plain id lookup.
    let id: String
    let name: String
    let description: String
    let category: String
    let author: String
    let skillURL: String
    let version: String
    let tags: [String]
}

struct CuratedSkillCatalog: Codable {
    let version: Int
    let skills: [CuratedSkill]
}

enum CuratedSkillCatalogError: LocalizedError {
    case missingBundleResource

    var errorDescription: String? {
        switch self {
        case .missingBundleResource:
            return String(localized: "找不到内置技能清单，请尝试重新安装应用。")
        }
    }
}

// MARK: - Catalog Loader

/// Abstraction over where the curated catalog comes from. Today: the JSON
/// shipped in the app bundle. Tomorrow: a remote endpoint — swap the
/// concrete loader at the `SkillStoreViewModel` call site.
protocol CuratedSkillCatalogLoading {
    func loadCatalog() async throws -> [CuratedSkill]
}

struct BundleCuratedSkillCatalogLoader: CuratedSkillCatalogLoading {
    func loadCatalog() async throws -> [CuratedSkill] {
        guard let url = Bundle.main.url(forResource: "CuratedSkills", withExtension: "json") else {
            throw CuratedSkillCatalogError.missingBundleResource
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CuratedSkillCatalog.self, from: data).skills
    }
}

// MARK: - Category Metadata

/// Raw `category` values in the JSON stay stable English keys; display
/// names are localized here so the catalog can be reordered/retitled
/// without re-shipping the file.
struct SkillStoreCategory: Identifiable, Hashable {
    /// nil = the "All" pseudo-category.
    let key: String?
    let title: String
    let systemImage: String

    var id: String { key ?? "all" }
}

// MARK: - View Model

@MainActor
final class SkillStoreViewModel: ObservableObject {
    @Published private(set) var skills: [CuratedSkill] = []
    @Published private(set) var isLoading = false
    @Published private(set) var loadError: String?
    @Published var selectedCategoryKey: String? = nil

    /// Ids currently going through the import pipeline.
    @Published private(set) var installingIDs: Set<String> = []
    /// Per-skill failure message from the last install attempt.
    @Published private(set) var failureByID: [String: String] = [:]

    private let catalogLoader: CuratedSkillCatalogLoading

    init(catalogLoader: CuratedSkillCatalogLoading = BundleCuratedSkillCatalogLoader()) {
        self.catalogLoader = catalogLoader
    }

    var filteredSkills: [CuratedSkill] {
        guard let key = selectedCategoryKey else { return skills }
        return skills.filter { $0.category == key }
    }

    func loadIfNeeded() async {
        guard !isLoading, skills.isEmpty, loadError == nil else { return }
        isLoading = true
        do {
            skills = try await catalogLoader.loadCatalog()
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    func retryLoad() async {
        loadError = nil
        await loadIfNeeded()
    }

    /// One-tap install: preflight + commit through the same pipeline the
    /// manual "Import from GitHub" sheet uses, including sibling-file
    /// (scripts/references/assets) downloads for full-featured skills.
    func install(_ item: CuratedSkill) async {
        failureByID[item.id] = nil
        installingIDs.insert(item.id)
        defer { installingIDs.remove(item.id) }
        do {
            _ = try await SkillStore.shared.importFromGitHub(urlString: item.skillURL)
        } catch {
            failureByID[item.id] = error.localizedDescription
        }
    }
}

// MARK: - Store View

struct SkillStoreView: View {
    @StateObject private var model = SkillStoreViewModel()
    @ObservedObject private var store = SkillStore.shared

    /// Categories actually present in the catalog, listed in the fixed
    /// display order below; empty ones are dropped.
    private let knownCategories: [SkillStoreCategory] = [
        SkillStoreCategory(key: "productivity", title: String(localized: "效率"), systemImage: "bolt"),
        SkillStoreCategory(key: "development", title: String(localized: "开发"), systemImage: "hammer"),
        SkillStoreCategory(key: "creation", title: String(localized: "创作"), systemImage: "paintbrush"),
        SkillStoreCategory(key: "data", title: String(localized: "数据"), systemImage: "chart.bar"),
        SkillStoreCategory(key: "life", title: String(localized: "生活"), systemImage: "house"),
    ]

    private var availableCategories: [SkillStoreCategory] {
        let present = Set(model.skills.map(\.category))
        return knownCategories.filter { present.contains($0.key ?? "") }
    }

    private let columns = [GridItem(.flexible(), spacing: OasesSpacing.sm, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: OasesSpacing.md) {
                categoryStrip
                content
            }
            .padding(.horizontal, OasesSpacing.md)
            .padding(.vertical, OasesSpacing.sm)
        }
        .background(OasesColor.background.ignoresSafeArea())
        .navigationTitle(String(localized: "技能商店"))
        .task { await model.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            HStack {
                Spacer()
                VStack(spacing: OasesSpacing.xs) {
                    ProgressView()
                    Text(String(localized: "正在加载精选技能…"))
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                }
                .padding(.vertical, OasesSpacing.xl)
                Spacer()
            }
        } else if let error = model.loadError {
            HStack {
                Spacer()
                VStack(spacing: OasesSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(OasesColor.mutedForeground)
                    Text(error)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .multilineTextAlignment(.center)
                    Button(String(localized: "重试")) {
                        Task { await model.retryLoad() }
                    }
                    .font(.oasesCalloutBold())
                    .foregroundStyle(OasesColor.primary)
                }
                .padding(.vertical, OasesSpacing.xl)
                Spacer()
            }
        } else if model.filteredSkills.isEmpty {
            Text(String(localized: "该分类下暂无技能"))
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .padding(.vertical, OasesSpacing.lg)
        } else {
            LazyVGrid(columns: columns, spacing: OasesSpacing.sm) {
                ForEach(model.filteredSkills) { item in
                    SkillStoreCard(
                        item: item,
                        isInstalled: isInstalled(item),
                        isInstalling: model.installingIDs.contains(item.id),
                        errorMessage: model.failureByID[item.id]
                    ) {
                        Task { await model.install(item) }
                    }
                }
            }
        }
    }

    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OasesSpacing.xs) {
                SkillStoreCategoryChip(
                    title: String(localized: "全部"),
                    systemImage: "square.grid.2x2",
                    isActive: model.selectedCategoryKey == nil
                ) {
                    withAnimation(.spring(response: 0.3)) {
                        model.selectedCategoryKey = nil
                    }
                }
                ForEach(availableCategories) { category in
                    SkillStoreCategoryChip(
                        title: category.title,
                        systemImage: category.systemImage,
                        isActive: model.selectedCategoryKey == category.key
                    ) {
                        withAnimation(.spring(response: 0.3)) {
                            model.selectedCategoryKey = category.key
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 2)
        }
    }

    /// A curated entry counts as installed when its id (the slug of the
    /// SKILL.md frontmatter name) is already in the store, or when any
    /// installed skill was imported from the same URL.
    private func isInstalled(_ item: CuratedSkill) -> Bool {
        if store.skills.contains(where: { $0.id == item.id }) { return true }
        return store.skills.contains { $0.sourceURL == item.skillURL }
    }
}

// MARK: - Category Chip

private struct SkillStoreCategoryChip: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: OasesSpacing.xxs) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.medium))
                Text(title)
                    .font(.oasesCaptionBold())
            }
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.xs)
            .foregroundStyle(isActive ? Color.white : OasesColor.foreground)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? OasesColor.primary : OasesColor.card)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Skill Card

private struct SkillStoreCard: View {
    let item: CuratedSkill
    let isInstalled: Bool
    let isInstalling: Bool
    let errorMessage: String?
    let installAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: OasesSpacing.xs) {
            HStack(alignment: .center, spacing: OasesSpacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.oasesCalloutBold())
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Text("\(item.author) · v\(item.version)")
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: OasesSpacing.xs)
                installButton
            }

            Text(item.description)
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(2)

            if !item.tags.isEmpty {
                HStack(spacing: OasesSpacing.xxs) {
                    ForEach(item.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.oasesFootnote())
                            .foregroundStyle(OasesColor.mutedForeground)
                            .padding(.horizontal, OasesSpacing.xs)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(OasesColor.muted)
                            )
                    }
                }
            }

            if let errorMessage, !isInstalling {
                HStack(alignment: .top, spacing: OasesSpacing.xxs) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.oasesCaption())
                    Text(errorMessage)
                        .font(.oasesCaption())
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(OasesColor.destructive)
            }
        }
        .padding(OasesSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
                .fill(OasesColor.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OasesRadius.lg, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var installButton: some View {
        if isInstalling {
            HStack(spacing: OasesSpacing.xxs) {
                ProgressView()
                    .controlSize(.small)
                Text(String(localized: "安装中"))
                    .font(.oasesCaptionBold())
            }
            .foregroundStyle(OasesColor.mutedForeground)
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.xs)
        } else if isInstalled {
            HStack(spacing: OasesSpacing.xxs) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                Text(String(localized: "已安装"))
                    .font(.oasesCaptionBold())
            }
            .foregroundStyle(OasesColor.emerald)
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.xs)
        } else {
            Button(installButtonTitle) {
                installAction()
            }
            .font(.oasesCaptionBold())
            .foregroundStyle(Color.white)
            .padding(.horizontal, OasesSpacing.sm)
            .padding(.vertical, OasesSpacing.xs)
            .background(
                Capsule(style: .continuous)
                    .fill(OasesColor.primary)
            )
        }
    }

    /// After a failed attempt the button doubles as "重试".
    private var installButtonTitle: String {
        errorMessage == nil ? String(localized: "安装") : String(localized: "重试")
    }
}
