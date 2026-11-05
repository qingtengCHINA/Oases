import Foundation

// i18n-ignore-file: tool-routing keyword tables matched against prompts, plus internal capability `reason` strings (ToolCapabilityCandidate.reason is never shown in UI); no user-visible text

/// Coarse-grained capabilities used during the first routing stage. The
/// capability list is intentionally much smaller than the tool schema list.
enum ToolCapability: String, Codable, Hashable, CaseIterable {
    case web
    case artifacts
    case media
    case trainTickets
    case shell
    case mcp
    case files
    case calendar
    case contacts
    case photos
    case location
    case metal
    case diagnostics
}

struct ToolCatalogEntry: Hashable {
    let descriptor: ToolDescriptor
    let capabilities: Set<ToolCapability>
    let keywords: Set<String>
    let priority: Int
    let isCore: Bool

    init(
        descriptor: ToolDescriptor,
        capabilities: Set<ToolCapability>,
        keywords: Set<String> = [],
        priority: Int = 0,
        isCore: Bool = false
    ) {
        self.descriptor = descriptor
        self.capabilities = capabilities
        self.keywords = keywords
        self.priority = priority
        self.isCore = isCore
    }
}

/// A compact first-stage result. It contains capability and tool names only;
/// it never contains input schemas or the full tool inventory.
struct ToolCapabilityCandidate: Hashable {
    let capability: ToolCapability
    let toolNames: [String]
    let score: Int
    let reason: String
}

struct ToolCatalog {
    let entries: [ToolCatalogEntry]

    init(descriptors: [ToolDescriptor]) {
        self.entries = descriptors.map { Self.entry(for: $0) }.sorted { lhs, rhs in
            lhs.descriptor.name < rhs.descriptor.name
        }
    }

    /// Returns a small capability shortlist. A zero-match result is important:
    /// greetings and ordinary chat must not cause any tool schema to be sent.
    func candidates(
        for prompt: String,
        surface: AgentSurface,
        limit: Int = 4
    ) -> [ToolCapabilityCandidate] {
        guard limit > 0 else { return [] }
        let normalized = prompt.lowercased()
        let tokens = Set(normalized.split { character in
            character.isWhitespace || character.isPunctuation || character.isSymbol
        }.map(String.init))

        let scored = ToolCapability.allCases.compactMap { capability -> ToolCapabilityCandidate? in
            let matching = entries.filter { entry in
                entry.descriptor.surfaces.contains(surface)
                    && entry.capabilities.contains(capability)
            }
            guard !matching.isEmpty else { return nil }

            let scoredEntries = matching.compactMap { entry -> (ToolCatalogEntry, Int)? in
                let entryScore = matchScore(
                    prompt: normalized,
                    tokens: tokens,
                    entry: entry,
                    capability: capability
                )
                guard entryScore > 0 else { return nil }
                return (entry, entryScore)
            }
            let score = scoredEntries.reduce(0) { $0 + $1.1 }
            guard score > 0 else { return nil }

            let names = scoredEntries
                .sorted { lhs, rhs in
                    if lhs.0.isCore != rhs.0.isCore { return lhs.0.isCore && !rhs.0.isCore }
                    if lhs.0.priority != rhs.0.priority { return lhs.0.priority > rhs.0.priority }
                    return lhs.0.descriptor.name < rhs.0.descriptor.name
                }
                .map { $0.0.descriptor.name }

            return ToolCapabilityCandidate(
                capability: capability,
                toolNames: names,
                score: score,
                reason: reason(for: capability)
            )
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.capability.rawValue < rhs.capability.rawValue
            }
            .prefix(limit)
            .map { $0 }
    }

    func coreToolNames(for names: Set<String>) -> Set<String> {
        Set(entries.filter { names.contains($0.descriptor.name) && $0.isCore }
            .map { $0.descriptor.name })
    }

    private func matchScore(
        prompt: String,
        tokens: Set<String>,
        entry: ToolCatalogEntry,
        capability: ToolCapability
    ) -> Int {
        var score = 0
        let name = entry.descriptor.name.lowercased()
        let summary = entry.descriptor.summary.lowercased()

        if entry.keywords.contains(where: { prompt.contains($0) }) { score += 3 }
        if entry.keywords.contains(where: { tokens.contains($0) }) { score += 2 }
        if name.split(separator: "_").contains(where: { tokens.contains(String($0)) }) { score += 2 }
        if summary.split(whereSeparator: { $0.isWhitespace }).contains(where: {
            tokens.contains(String($0))
        }) { score += 1 }

        // Chinese prompts are commonly not whitespace-tokenized.
        if chineseHints(for: capability).contains(where: { prompt.contains($0) }) { score += 4 }
        return score
    }

    private static func entry(for descriptor: ToolDescriptor) -> ToolCatalogEntry {
        let name = descriptor.name.lowercased()
        let text = "\(name) \(descriptor.displayName) \(descriptor.summary)".lowercased()
        var capabilities = Set<ToolCapability>()
        var keywords = Set<String>()
        var priority = 0

        func add(_ capability: ToolCapability, _ words: [String], _ value: Int = 0) {
            capabilities.insert(capability)
            words.forEach { keywords.insert($0.lowercased()) }
            priority = max(priority, value)
        }

        if containsAny(text, ["web", "browse", "search", "网页", "浏览", "搜索", "agent_reach", "logo_fetch"]) {
            add(.web, ["web", "browse", "search", "网页", "浏览", "搜索", "url", "http"], 5)
        }
        if containsAny(text, ["artifact", "ppt", "docx", "word", "pdf", "document", "演示", "文档"]) {
            add(.artifacts, ["ppt", "pptx", "docx", "word", "pdf", "文档", "演示文稿", "幻灯片", "产物"], 8)
        }
        if containsAny(text, ["youtube", "video", "media", "视频", "下载"]) {
            add(.media, ["youtube", "video", "视频", "下载", "mp4", "media"], 7)
        }
        if containsAny(text, ["12306", "train", "ticket", "railway", "火车", "高铁", "车票", "列车"]) {
            add(.trainTickets, ["12306", "train", "ticket", "railway", "火车", "高铁", "动车", "车票", "余票", "列车"], 9)
        }
        if containsAny(text, ["shell", "shell_execute", "shell_local", "ogent_agent", "terminal", "命令", "脚本", "linux", "ish"]) {
            add(.shell, ["shell", "shell_execute", "shell_local", "terminal", "命令", "脚本", "linux", "ish", "执行"], 6)
        }
        if containsAny(text, ["mcp", "context protocol", "工具服务器"]) {
            add(.mcp, ["mcp", "server", "工具服务器"], 4)
        }
        if containsAny(text, ["file", "file_edit", "文件", "write", "read", "edit", "workspace", "工作区", "oases"]) {
            add(.files, ["file", "file_edit", "文件", "write", "read", "edit", "workspace", "工作区", "oases"], 3)
        }
        if containsAny(text, ["calendar", "日历", "提醒", "reminder"]) { add(.calendar, ["calendar", "日历", "提醒", "reminder"], 4) }
        if containsAny(text, ["contact", "联系人", "通讯录"]) { add(.contacts, ["contact", "联系人", "通讯录"], 4) }
        if containsAny(text, ["photo", "照片", "相册"]) { add(.photos, ["photo", "照片", "相册"], 4) }
        if containsAny(text, ["location", "定位", "位置"]) { add(.location, ["location", "定位", "位置"], 4) }
        if containsAny(text, ["clipboard", "pasteboard", "剪贴板", "粘贴", "apple_clipboard", "apple-clipboard"]) {
            add(.diagnostics, ["clipboard", "pasteboard", "剪贴板", "粘贴", "clipboard"], 5)
        }
        if containsAny(text, ["metal", "gpu", "加速"]) { add(.metal, ["metal", "gpu", "加速"], 4) }
        if containsAny(text, ["health_check", "capability", "selftest", "诊断", "检查", "状态"]) {
            add(.diagnostics, ["health_check", "capability", "selftest", "诊断", "检查", "状态"], 2)
        }

        // Unknown descriptors still get a useful fallback classification from
        // the descriptor text, while remaining invisible for unrelated prompts.
        if capabilities.isEmpty, descriptor.surfaces.contains(.project) {
            keywords.formUnion(name.split(separator: "_").map(String.init))
        }

        let isCore = ["ogent_agent", "shell_execute", "shell_local", "artifact_bridge", "file_read", "file_write", "file_edit"].contains(name)
            || name.contains("artifact_bridge")
            || name.contains("shell_execute")
            || name.contains("shell_local")
            || name.contains("ogent_agent")

        return ToolCatalogEntry(
            descriptor: descriptor,
            capabilities: capabilities,
            keywords: keywords,
            priority: priority,
            isCore: isCore
        )
    }

    private func reason(for capability: ToolCapability) -> String {
        switch capability {
        case .web: return "网页访问与检索"
        case .artifacts: return "文档或演示文稿产物"
        case .media: return "媒体下载与处理"
        case .trainTickets: return "12306 火车票查询"
        case .shell: return "Linux/iSH 命令执行"
        case .mcp: return "MCP 工具调用"
        case .files: return "文件与工作区操作"
        case .calendar: return "日历与提醒"
        case .contacts: return "联系人"
        case .photos: return "照片"
        case .location: return "位置"
        case .metal: return "Metal/GPU 加速"
        case .diagnostics: return "运行状态诊断"
        }
    }

    private func chineseHints(for capability: ToolCapability) -> [String] {
        switch capability {
        case .web: return ["网页", "浏览", "搜索", "网站", "链接", "新闻", "抓取", "爬取"]
        case .artifacts: return ["ppt", "pptx", "演示文稿", "幻灯片", "word", "文档", "产物", "报告"]
        case .media: return ["视频", "下载", "媒体", "youtube"]
        case .trainTickets: return ["12306", "火车票", "高铁", "动车", "车票", "余票", "列车"]
        case .shell: return ["命令", "脚本", "终端", "linux", "ish", "执行"]
        case .mcp: return ["mcp", "工具服务器"]
        case .files: return ["文件", "工作区", "保存"]
        case .calendar: return ["日历", "提醒"]
        case .contacts: return ["联系人", "通讯录"]
        case .photos: return ["照片", "相册"]
        case .location: return ["位置", "定位"]
        case .metal: return ["metal", "gpu", "加速"]
        case .diagnostics: return ["检查", "诊断", "状态", "测试"]
        }
    }

    private static func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.contains($0.lowercased()) }
    }
}
