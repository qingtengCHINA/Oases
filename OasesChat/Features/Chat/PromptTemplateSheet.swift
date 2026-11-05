import SwiftUI

struct PromptTemplate: Identifiable, Hashable {
    let icon: String
    let title: String
    let prompt: String
    let category: Category

    /// Titles are unique, so they give the grid a stable identity even
    /// though the (localized) library is rebuilt on every access.
    var id: String { title }

    enum Category: String, CaseIterable {
        case writing = "写作" // i18n-ignore: identifier; shown via displayName
        case analysis = "分析" // i18n-ignore: identifier; shown via displayName
        case coding = "代码" // i18n-ignore: identifier; shown via displayName
        case creative = "创意" // i18n-ignore: identifier; shown via displayName
        case learning = "学习" // i18n-ignore: identifier; shown via displayName

        var displayName: String {
            switch self {
            case .writing: return String(localized: "写作", comment: "Prompt template category")
            case .analysis: return String(localized: "分析", comment: "Prompt template category")
            case .coding: return String(localized: "代码", comment: "Prompt template category")
            case .creative: return String(localized: "创意", comment: "Prompt template category")
            case .learning: return String(localized: "学习", comment: "Prompt template category")
            }
        }
    }
}

struct PromptTemplateSheet: View {
    var onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedCategory: PromptTemplate.Category = .writing
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                categoryPicker
                    .padding(.horizontal, OasesSpacing.md)
                    .padding(.top, OasesSpacing.xs)

                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.flexible()), GridItem(.flexible())],
                        spacing: OasesSpacing.sm
                    ) {
                        ForEach(filtered) { template in
                            templateCard(template)
                        }
                    }
                    .padding(.horizontal, OasesSpacing.md)
                    .padding(.vertical, OasesSpacing.md)
                }
            }
            .navigationTitle("提示词模板")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索模板")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: OasesSpacing.xs) {
                ForEach(PromptTemplate.Category.allCases, id: \.self) { cat in
                    Button {
                        selectedCategory = cat
                        Haptics.select()
                    } label: {
                        Text(cat.displayName)
                            .font(.oasesCaption())
                            .padding(.horizontal, OasesSpacing.sm)
                            .padding(.vertical, 6)
                            .foregroundStyle(selectedCategory == cat ? OasesColor.primary : OasesColor.mutedForeground)
                            .background(
                                Capsule()
                                    .fill(selectedCategory == cat ? OasesColor.primary.opacity(0.14) : OasesColor.card.opacity(0.4))
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        selectedCategory == cat ? OasesColor.primary.opacity(0.5) : OasesColor.border.opacity(0.3),
                                        lineWidth: 0.5
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filtered: [PromptTemplate] {
        let base = searchText.isEmpty
            ? allTemplates.filter { $0.category == selectedCategory }
            : allTemplates.filter { $0.title.localizedCaseInsensitiveContains(searchText) || $0.prompt.localizedCaseInsensitiveContains(searchText) }
        return base
    }

    @ViewBuilder
    private func templateCard(_ template: PromptTemplate) -> some View {
        Button {
            onSelect(template.prompt)
            dismiss()
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: OasesSpacing.xs) {
                Text(template.icon)
                    .font(.system(size: 24))
                Text(template.title)
                    .font(.custom(OasesTypography.serifBold, size: 14, relativeTo: .body))
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(template.prompt)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(OasesSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .fill(OasesColor.card.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .strokeBorder(OasesColor.border.opacity(0.4), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Template Library

// Built on access so the copy follows an in-app language change.
private var allTemplates: [PromptTemplate] { [
    // Writing
    PromptTemplate(icon: "✍️", title: String(localized: "精炼表达", comment: "Prompt template title"), prompt: String(localized: "请帮我将以下内容改写得更简洁、专业：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),
    PromptTemplate(icon: "📧", title: String(localized: "商务邮件", comment: "Prompt template title"), prompt: String(localized: "请帮我写一封关于[主题]的商务邮件，收件人是[职位]，语气正式而友好。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),
    PromptTemplate(icon: "📝", title: String(localized: "报告摘要", comment: "Prompt template title"), prompt: String(localized: "请对以下内容生成一份 3 段的执行摘要，包含关键数据和行动项：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),
    PromptTemplate(icon: "🌐", title: String(localized: "中英互译", comment: "Prompt template title"), prompt: String(localized: "请将以下内容翻译成英文，保持原意和专业术语：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),
    PromptTemplate(icon: "📖", title: String(localized: "文章大纲", comment: "Prompt template title"), prompt: String(localized: "请为「[主题]」生成一份包含 5 个核心章节的详细文章大纲。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),
    PromptTemplate(icon: "💬", title: String(localized: "优化语气", comment: "Prompt template title"), prompt: String(localized: "请将以下文字改写得更自然、更具说服力，同时保留核心信息：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .writing),

    // Analysis
    PromptTemplate(icon: "🔍", title: String(localized: "SWOT 分析", comment: "Prompt template title"), prompt: String(localized: "请对以下主题做 SWOT 分析（优势、劣势、机会、威胁）：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),
    PromptTemplate(icon: "📊", title: String(localized: "数据解读", comment: "Prompt template title"), prompt: String(localized: "请分析以下数据，找出关键趋势和异常值，并给出建议：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),
    PromptTemplate(icon: "⚖️", title: String(localized: "利弊权衡", comment: "Prompt template title"), prompt: String(localized: "请列出「[选项]」的利与弊各 5 条，并给出最终建议。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),
    PromptTemplate(icon: "🎯", title: String(localized: "根因分析", comment: "Prompt template title"), prompt: String(localized: "请用 5-Why 方法分析以下问题的根本原因：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),
    PromptTemplate(icon: "📈", title: String(localized: "市场分析", comment: "Prompt template title"), prompt: String(localized: "请对「[行业/产品]」做一份市场分析，包括目标用户、竞品对比和机会点。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),
    PromptTemplate(icon: "🧩", title: String(localized: "方案对比", comment: "Prompt template title"), prompt: String(localized: "请对以下几个方案从技术可行性、成本、风险三个维度进行对比分析：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .analysis),

    // Coding
    PromptTemplate(icon: "🐛", title: String(localized: "代码审查", comment: "Prompt template title"), prompt: String(localized: "请审查以下代码，找出潜在 Bug、性能问题和安全漏洞：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),
    PromptTemplate(icon: "⚡️", title: String(localized: "性能优化", comment: "Prompt template title"), prompt: String(localized: "请对以下代码提出具体的性能优化建议：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),
    PromptTemplate(icon: "🧪", title: String(localized: "单元测试", comment: "Prompt template title"), prompt: String(localized: "请为以下函数编写完整的单元测试用例，覆盖边界条件：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),
    PromptTemplate(icon: "📚", title: String(localized: "解释代码", comment: "Prompt template title"), prompt: String(localized: "请用通俗语言解释以下代码的作用和工作原理：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),
    PromptTemplate(icon: "🔄", title: String(localized: "重构建议", comment: "Prompt template title"), prompt: String(localized: "请对以下代码提出重构建议，使其更易维护、更符合最佳实践：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),
    PromptTemplate(icon: "🛡️", title: String(localized: "安全检查", comment: "Prompt template title"), prompt: String(localized: "请检查以下代码是否存在 SQL 注入、XSS、CSRF 等安全漏洞：\n\n```\n\n```", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .coding),

    // Creative
    PromptTemplate(icon: "🎨", title: String(localized: "品牌故事", comment: "Prompt template title"), prompt: String(localized: "请为「[品牌/产品]」创作一个打动人心的品牌故事，200 字以内。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .creative),
    PromptTemplate(icon: "🌟", title: String(localized: "头脑风暴", comment: "Prompt template title"), prompt: String(localized: "请围绕「[主题]」进行头脑风暴，生成 10 个不同角度的创意想法。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .creative),
    PromptTemplate(icon: "🎬", title: String(localized: "脚本创作", comment: "Prompt template title"), prompt: String(localized: "请为以下场景写一段对话脚本，时长约 2 分钟：\n\n", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .creative),
    PromptTemplate(icon: "🏷️", title: String(localized: "标语创作", comment: "Prompt template title"), prompt: String(localized: "请为「[产品/活动]」创作 5 个朗朗上口的广告标语。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .creative),

    // Learning
    PromptTemplate(icon: "🎓", title: String(localized: "概念解释", comment: "Prompt template title"), prompt: String(localized: "请用小学生能理解的语言解释「[概念]」，并举 2 个生活中的例子。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .learning),
    PromptTemplate(icon: "❓", title: String(localized: "提问练习", comment: "Prompt template title"), prompt: String(localized: "请就「[主题]」提出 10 个由浅入深的学习问题。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .learning),
    PromptTemplate(icon: "🗺️", title: String(localized: "知识地图", comment: "Prompt template title"), prompt: String(localized: "请绘制「[领域]」的知识体系框架，列出核心概念及其关联关系。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .learning),
    PromptTemplate(icon: "📋", title: String(localized: "学习计划", comment: "Prompt template title"), prompt: String(localized: "请为「[技能/领域]」制定一份 30 天学习计划，每天 1 小时。", comment: "Prompt template text inserted into the composer; keep the [placeholders] and code fences"), category: .learning),
] }
