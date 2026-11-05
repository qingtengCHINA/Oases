import SwiftUI

/// 最近删除: what the file browser deleted in the last 30 days. Restore puts an item back where it
/// was; Delete Permanently and Delete All are the only places that destroy it.
struct RecentlyDeletedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [FileTrashEntry] = []
    @State private var entryToDestroy: FileTrashEntry?
    @State private var confirmDeleteAll = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView(
                    String(localized: "No Recently Deleted Items", comment: "Recently Deleted: empty state title"),
                    systemImage: "trash"
                )
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        row(entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    entryToDestroy = entry
                                } label: {
                                    Label(String(localized: "Delete Permanently", comment: "Recently Deleted: destroy one item"), systemImage: "trash.slash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    restore(entry)
                                } label: {
                                    Label(String(localized: "Restore", comment: "Recently Deleted: put an item back where it was"), systemImage: "arrow.uturn.backward")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    restore(entry)
                                } label: {
                                    Label(String(localized: "Restore", comment: "Recently Deleted: put an item back where it was"), systemImage: "arrow.uturn.backward")
                                }
                                Button(role: .destructive) {
                                    entryToDestroy = entry
                                } label: {
                                    Label(String(localized: "Delete Permanently", comment: "Recently Deleted: destroy one item"), systemImage: "trash.slash")
                                }
                            }
                    }
                } footer: {
                    Text(String(localized: "Items are removed for good 30 days after you delete them.", comment: "Recently Deleted: footer explaining the retention"))
                }
            }
        }
        .navigationTitle(String(localized: "Recently Deleted", comment: "Recently Deleted: page title and file browser menu item"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Done", comment: "Recently Deleted: close the page")) { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Delete All", comment: "Recently Deleted: destroy every item"), role: .destructive) {
                    confirmDeleteAll = true
                }
                .disabled(entries.isEmpty)
            }
        }
        .onAppear(perform: reload)
        .alert(
            String(localized: "Delete “\(entryToDestroy?.name ?? "")” permanently?", comment: "Recently Deleted: confirm destroying one item; argument is the file name"),
            isPresented: Binding(get: { entryToDestroy != nil }, set: { if !$0 { entryToDestroy = nil } })
        ) {
            Button(String(localized: "Delete Permanently", comment: "Recently Deleted: destroy one item"), role: .destructive) {
                if let entry = entryToDestroy { destroy(entry) }
                entryToDestroy = nil
            }
            Button(String(localized: "Cancel", comment: "Recently Deleted: keep the item"), role: .cancel) { entryToDestroy = nil }
        } message: {
            Text(String(localized: "This can't be undone.", comment: "Recently Deleted: warning before destroying items"))
        }
        .alert(
            String(localized: "Delete everything in Recently Deleted?", comment: "Recently Deleted: confirm destroying every item"),
            isPresented: $confirmDeleteAll
        ) {
            Button(String(localized: "Delete All", comment: "Recently Deleted: destroy every item"), role: .destructive) {
                FileTrash.deleteAllPermanently()
                reload()
            }
            Button(String(localized: "Cancel", comment: "Recently Deleted: keep the item"), role: .cancel) {}
        } message: {
            Text(String(localized: "This can't be undone.", comment: "Recently Deleted: warning before destroying items"))
        }
        .alert(
            String(localized: "Couldn't Restore", comment: "Recently Deleted: error alert title"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "OK", comment: "Recently Deleted: dismiss the error"), role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func row(_ entry: FileTrashEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.blue : Color.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.displayLocation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(entry.deletedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func reload() {
        entries = FileTrash.entries()
    }

    private func restore(_ entry: FileTrashEntry) {
        do {
            try FileTrash.restore(entry)
        } catch {
            errorMessage = error.localizedDescription
        }
        reload()
    }

    private func destroy(_ entry: FileTrashEntry) {
        try? FileTrash.deletePermanently(entry)
        reload()
    }
}
