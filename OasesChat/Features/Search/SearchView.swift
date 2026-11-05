import SwiftUI
import SwiftData

struct SearchView: View {
    var onSelectConversation: (ConversationModel) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ConversationModel.updatedAt, order: .reverse)
    private var conversations: [ConversationModel]

    @State private var searchText = ""
    /// Results for `resultsQuery`, refreshed by a debounced store fetch
    /// instead of faulting in every message of every conversation on each
    /// keystroke.
    @State private var results: [(ConversationModel, MessageModel?)] = []
    @State private var resultsQuery = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if searchText.isEmpty {
                    recentsList
                } else if results.isEmpty {
                    if resultsQuery == searchText {
                        emptyState
                    } else {
                        Color.clear
                    }
                } else {
                    resultsList
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, isPresented: .constant(true), prompt: "搜索对话内容")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { dismiss() }
                }
            }
            .task(id: searchText) {
                let query = searchText
                guard !query.isEmpty else {
                    results = []
                    resultsQuery = ""
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                results = Self.search(query, in: conversations, context: modelContext)
                resultsQuery = query
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Recents

    private var recentsList: some View {
        List {
            if conversations.isEmpty {
                ContentUnavailableView("暂无对话记录", systemImage: "bubble.left")
            } else {
                Section("最近对话") {
                    ForEach(conversations) { conv in
                        conversationRow(conv, highlight: nil)
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    // MARK: - Search Results

    /// Conversations (newest first) whose title matches, else the earliest
    /// message that does. Message text is matched by one predicate fetch in
    /// the store; only matching rows are materialised.
    private static func search(
        _ query: String,
        in conversations: [ConversationModel],
        context: ModelContext
    ) -> [(ConversationModel, MessageModel?)] {
        let predicate = #Predicate<MessageModel> { msg in
            msg.content.localizedStandardContains(query)
        }
        var descriptor = FetchDescriptor<MessageModel>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.createdAt)]
        )
        descriptor.propertiesToFetch = [\.content, \.createdAt]
        let matches: [MessageModel]
        do {
            matches = try context.fetch(descriptor)
        } catch {
            NSLog("[Search] message fetch failed: \(error.localizedDescription)")
            matches = []
        }
        var firstMatch: [UUID: MessageModel] = [:]
        for message in matches {
            guard let convId = message.conversation?.id, firstMatch[convId] == nil else { continue }
            firstMatch[convId] = message
        }

        var found: [(ConversationModel, MessageModel?)] = []
        for conv in conversations {
            if conv.title.range(of: query, options: SearchSnippet.matchOptions) != nil {
                found.append((conv, nil))
            } else if let match = firstMatch[conv.id] {
                found.append((conv, match))
            }
        }
        return found
    }

    private var resultsList: some View {
        List {
            Section("\(results.count) 个结果") {
                ForEach(results, id: \.0.id) { conv, matchMsg in
                    conversationRow(conv, highlight: matchMsg)
                }
            }
        }
        .listStyle(.plain)
    }

    private var emptyState: some View {
        ContentUnavailableView.search(text: searchText)
    }

    // MARK: - Row

    @ViewBuilder
    private func conversationRow(_ conv: ConversationModel, highlight: MessageModel?) -> some View {
        Button {
            onSelectConversation(conv)
            dismiss()
            Haptics.tap()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: conv.mode.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(OasesColor.primary)
                    Text(conv.title)
                        .font(.custom(OasesTypography.serifBold, size: 15, relativeTo: .body))
                        .foregroundStyle(OasesColor.foreground)
                        .lineLimit(1)
                    Spacer()
                    Text(conv.updatedAt, style: .relative)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                }

                if let msg = highlight {
                    highlightedSnippet(msg.content, query: searchText)
                } else {
                    Text(Models.label(for: conv.modelId, category: conv.mode.category))
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.mutedForeground)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func highlightedSnippet(_ text: String, query: String) -> some View {
        if let parts = SearchSnippet.split(text, query: query) {
            (Text(parts.before) +
             Text(parts.match).foregroundColor(OasesColor.primary).bold() +
             Text(parts.after))
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(2)
        } else {
            Text(String(text.prefix(80)))
                .font(.oasesCaption())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(2)
        }
    }
}


/// Highlight split for a search result row.
enum SearchSnippet {
    /// Same looseness as the store predicate (`localizedStandardContains`).
    static let matchOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Splits `text` around the first match of `query`: up to 30 characters
    /// before, the match itself, up to 60 after. The range comes from a
    /// case-insensitive search of `text` itself — a range found in
    /// `text.lowercased()` indexes a different string and crashed when
    /// lowercasing changed its length ("İ", the Kelvin sign…).
    static func split(_ text: String, query: String) -> (before: String, match: String, after: String)? {
        guard !query.isEmpty,
              let range = text.range(of: query, options: matchOptions) else { return nil }
        return (
            String(text[..<range.lowerBound].suffix(30)),
            String(text[range]),
            String(text[range.upperBound...].prefix(60))
        )
    }
}
