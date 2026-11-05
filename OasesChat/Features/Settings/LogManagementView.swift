import SwiftUI
import UIKit

// MARK: - View Model

class LogManagementViewModel: ObservableObject {
    struct LogFile: Identifiable {
        let id: String
        let name: String
        let url: URL
        let date: Date
        let size: Int64
        let type: String  // "running" | "crash" | "other"
    }

    @Published var logFiles: [LogFile] = []
    @Published var totalSize: Int64 = 0

    /// Running + other logs (non-crash). Shown in the "Log Files" section.
    var runningFiles: [LogFile] { logFiles.filter { $0.type != "crash" } }
    /// Crash reports (crash-*.log). Shown in a separate section only if non-empty.
    var crashFiles: [LogFile] { logFiles.filter { $0.type == "crash" } }

    private let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    func format(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: bytes)
    }

    func load() {
        let files = LoggingManager.shared.logFiles()
        logFiles = files.map {
            LogFile(id: $0.name, name: $0.name, url: $0.url, date: $0.date, size: $0.size, type: $0.type)
        }
        totalSize = LoggingManager.shared.totalLogSize()
    }
}

// MARK: - Log Management View

struct LogManagementView: View {
    @StateObject private var vm = LogManagementViewModel()
    @ObservedObject private var loggingManager = LoggingManager.shared
    @State private var showDeleteAllConfirm = false
    /// Logs the user asked to export; the export modifier confirms, then
    /// shares sanitised copies.
    @State private var exportRequest: [URL]?

    /// Selected top-level tab. Bound to a deep-link query string so
    /// `minis://settings/logs?tab=config-audit` lands users straight on
    /// the audit list. Stored as a String so the Picker can drive it.
    @State var initialTab: String = "logs"
    @State private var tab: String = "logs"

    init(initialTab: String = "logs") {
        _initialTab = State(initialValue: initialTab)
        _tab = State(initialValue: initialTab == "crashes" ? "logs" : initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Tab", selection: $tab) {
                Text("Logs").tag("logs")
                Text("Config Changes").tag("config-audit")
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            if tab == "config-audit" {
                ConfigAuditView()
            } else {
                logsBody
            }
        }
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // "crashes" is no longer a tab — crash reports now live in a
            // section of the Logs body. Fall back to "logs" for stale deep links.
            tab = (initialTab == "crashes") ? "logs" : initialTab
            vm.load()
        }
    }

    @ViewBuilder
    private var logsBody: some View {
        List {
            Section {
                Toggle("Enable Logging", isOn: $loggingManager.isEnabled)
            } footer: {
                Text("When enabled, all console output is captured to daily log files.")
            }

            Section("Log Files") {
                if vm.runningFiles.isEmpty {
                    Text("No log files")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(vm.runningFiles) { file in
                        NavigationLink {
                            LogDetailView(url: file.url, name: file.name)
                        } label: {
                            HStack {
                                Text(file.name)
                                    .lineLimit(1)
                                Spacer()
                                Text(vm.format(file.size))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let files = vm.runningFiles
                        for index in indexSet {
                            LoggingManager.shared.deleteLog(at: files[index].url)
                        }
                        vm.load()
                    }
                }
            }

            if !vm.crashFiles.isEmpty {
                Section("Crash Reports") {
                    ForEach(vm.crashFiles) { file in
                        NavigationLink {
                            LogDetailView(url: file.url, name: file.name)
                        } label: {
                            HStack {
                                Text("⚠️ \(file.name)")
                                    .lineLimit(1)
                                Spacer()
                                Text(vm.format(file.size))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let files = vm.crashFiles
                        for index in indexSet {
                            LoggingManager.shared.deleteLog(at: files[index].url)
                        }
                        vm.load()
                    }
                }
            }

            if !vm.logFiles.isEmpty {
                Section {
                    Button(role: .destructive) {
                        showDeleteAllConfirm = true
                    } label: {
                        HStack {
                            Label("Delete All Logs", systemImage: "trash")
                            Spacer()
                            Text(vm.format(vm.totalSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("Total log storage: \(vm.format(vm.totalSize))")
                }
            }
        }
        .toolbar {
            if !vm.logFiles.isEmpty && tab == "logs" {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportRequest = vm.logFiles.map(\.url)
                    } label: {
                        Label(String(localized: "导出日志", comment: "Logs screen: toolbar button that exports log files"), systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .sanitizedLogExport($exportRequest)
        .alert("Delete All Logs?", isPresented: $showDeleteAllConfirm) {
            Button("Delete All", role: .destructive) {
                LoggingManager.shared.deleteAllLogs()
                vm.load()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete \(vm.format(vm.totalSize)) of log files. This action cannot be undone.")
        }
    }
}

// MARK: - Log Detail View

struct LogDetailView: View {
    let url: URL
    let name: String
    @State private var content: String = ""
    @State private var isLoading = true
    @State private var exportRequest: [URL]?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                LogTextView(text: content)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // [T-log-redaction] Not a ShareLink to the raw file: exports go
                // through the same confirmation and sanitised copy as the list.
                Button {
                    exportRequest = [url]
                } label: {
                    Label(String(localized: "导出日志", comment: "Logs screen: toolbar button that exports log files"), systemImage: "square.and.arrow.up")
                }
            }
        }
        .sanitizedLogExport($exportRequest)
        .task {
            let fileURL = url
            let loaded = await Task.detached(priority: .userInitiated) {
                LoggingManager.shared.readLog(at: fileURL)
            }.value
            content = loaded
            isLoading = false
        }
    }
}

// MARK: - UITextView wrapper (TextKit 2 lazy layout)

private struct LogTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.dataDetectorTypes = []
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        if textView.text != text {
            textView.text = text
        }
    }
}

// MARK: - Sanitised Export

/// [T-log-redaction] Every log export: say first that logs can hold
/// conversation content, then share sanitised copies (LoggingManager
/// .sanitizedExportCopies) instead of the files themselves. The daily log
/// captures all console output, and builds before this change wrote request
/// bodies, token prefixes and message-text previews into it.
private struct SanitizedLogExportModifier: ViewModifier {
    @Binding var request: [URL]?
    @State private var preparedURLs: [URL] = []
    @State private var showShareSheet = false
    @State private var isPreparing = false
    @State private var showFailure = false

    func body(content: Content) -> some View {
        content
            .alert(
                String(localized: "导出日志？", comment: "Logs export confirmation title"),
                isPresented: Binding(
                    get: { request != nil },
                    set: { if !$0 { request = nil } }
                ),
                presenting: request
            ) { urls in
                Button(String(localized: "导出", comment: "Logs export confirmation: export button")) {
                    prepare(urls)
                }
                Button(String(localized: "取消"), role: .cancel) {}
            } message: { _ in
                Text(String(localized: "日志可能包含对话内容，例如消息片段、命令、文件名和网址。导出前会移除密钥、令牌、请求正文和邮箱地址，但无法保证全部去除。请只分享给你信任的人。", comment: "Logs export confirmation message: warns that logs may contain conversation content"))
            }
            .alert(
                String(localized: "无法导出日志", comment: "Logs export failure title"),
                isPresented: $showFailure
            ) {
                Button(String(localized: "好"), role: .cancel) {}
            } message: {
                Text(String(localized: "没能生成可分享的日志副本，请稍后重试。", comment: "Logs export failure message"))
            }
            .sheet(isPresented: $showShareSheet) {
                LogShareSheet(urls: preparedURLs)
            }
            .overlay {
                if isPreparing {
                    ProgressView()
                        .controlSize(.large)
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(isPreparing)
    }

    private func prepare(_ urls: [URL]) {
        isPreparing = true
        Task {
            // Sanitising streams every file through regexes: off the main thread.
            let copies = await Task.detached(priority: .userInitiated) {
                LoggingManager.shared.sanitizedExportCopies(of: urls)
            }.value
            isPreparing = false
            if copies.isEmpty {
                showFailure = true
            } else {
                preparedURLs = copies
                showShareSheet = true
            }
        }
    }
}

private extension View {
    func sanitizedLogExport(_ request: Binding<[URL]?>) -> some View {
        modifier(SanitizedLogExportModifier(request: request))
    }
}

// MARK: - Share Sheet

private struct LogShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // [T-share-sheet-uti] See OasesShareSheet.sanitizedShareURL.
        let safe = urls.map { OasesShareSheet.sanitizedShareURL($0) ?? $0 }
        return UIActivityViewController(activityItems: safe, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
