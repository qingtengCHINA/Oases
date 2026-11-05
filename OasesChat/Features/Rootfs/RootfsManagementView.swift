import SwiftUI

// Extracted from Features/Settings/SettingsView.swift (Stage 1.3).
// Rootfs management + browser live under Features/Rootfs so Settings stays a
// thin router into domain modules rather than a 2000-line kitchen sink.

struct RootfsManagementView: View {
    @State private var status = ISHRootfsManager.status()
    @State private var isBusy = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var commandOutput = ""
    @State private var showResetConfirm = false

    var body: some View {
        List {
            Section("状态") {
                statusRow("checkmark.circle.fill", String(localized: "已安装"), status.installed ? String(localized: "是", comment: "Rootfs installed: yes") : String(localized: "否", comment: "Rootfs installed: no"), status.installed ? OasesColor.emerald : OasesColor.destructive)
                statusRow("terminal.fill", String(localized: "运行时"), status.runtimeReady ? String(localized: "运行中") : String(localized: "未启动"), status.runtimeReady ? OasesColor.emerald : OasesColor.mutedForeground)
                statusRow("shippingbox.fill", String(localized: "大小"), status.totalSizeLabel, OasesColor.primary)
                statusRow("doc.on.doc.fill", String(localized: "文件"), String(localized: "\(status.fileCount) 项"), OasesColor.primary)
                statusRow("mountain.2.fill", "Alpine", status.alpineVersion ?? String(localized: "unknown"), OasesColor.primary)
                statusRow("folder.fill", String(localized: "路径"), compactPath(status.rootURL.path), OasesColor.primary)
                if status.pendingReset {
                    statusRow("arrow.clockwise.circle.fill", String(localized: "下次启动"), String(localized: "将重置 Rootfs"), OasesColor.destructive)
                }
            }

            Section("浏览") {
                NavigationLink {
                    RootfsBrowserView(url: status.dataURL, guestPath: "/")
                } label: {
                    statusRow("folder.fill", String(localized: "浏览文件"), String(localized: "查看 Alpine rootfs"), OasesColor.primary)
                }
            }

            Section("镜像") {
                Button {
                    runCommand(
                        title: String(localized: "侦测快速镜像"),
                        command: rootfsProbeCommand,
                        timeout: 20
                    )
                } label: {
                    actionLabel("bolt.fill", String(localized: "侦测快速镜像"), color: .orange)
                }
                Button {
                    runCommand(title: "Alpine APK", command: "apk update", timeout: 90)
                } label: {
                    actionLabel("mountain.2.fill", "Alpine APK", color: OasesColor.primary)
                }
                Button {
                    runCommand(title: "Python pip", command: "apk update && apk add python3 py3-pip", timeout: 180)
                } label: {
                    actionLabel("cube.fill", "Python pip", color: OasesColor.emerald)
                }
                Button {
                    runCommand(title: "Node.js npm", command: "apk update && apk add nodejs npm", timeout: 180)
                } label: {
                    actionLabel("cube.fill", "Node.js npm", color: OasesColor.destructive)
                }
            }
            .disabled(isBusy)

            Section {
                Button {
                    runCommand(title: "Rootfs Doctor", command: "/bin/sh /usr/local/bin/ogent-agent rootfs-doctor", timeout: 30)
                } label: {
                    actionLabel("stethoscope", "Rootfs Doctor", color: OasesColor.primary)
                }

                Button {
                    runCommand(title: "Rootfs Repair", command: "/bin/sh /usr/local/bin/ogent-agent rootfs-repair", timeout: 300)
                } label: {
                    actionLabel("wrench.and.screwdriver.fill", String(localized: "修复 Rootfs"), color: OasesColor.emerald)
                }

                Button {
                    runCommand(title: String(localized: "工程依赖状态"), command: "/bin/sh /usr/local/bin/ogent-agent profile-status core", timeout: 20)
                } label: {
                    actionLabel("checklist", String(localized: "检查 Core Profile"), color: OasesColor.primary)
                }

                Button {
                    runCommand(title: String(localized: "12306 MCP 依赖状态"), command: "/bin/sh /usr/local/bin/ogent-agent profile-status 12306", timeout: 20)
                } label: {
                    actionLabel("train.side.front.car", String(localized: "检查 12306 MCP Profile"), color: OasesColor.primary)
                }

                Button {
                    runCommand(title: String(localized: "本机模型依赖状态"), command: "/bin/sh /usr/local/bin/ogent-agent profile-status local-model", timeout: 20)
                } label: {
                    actionLabel("cpu.fill", String(localized: "检查 Local Model Profile"), color: OasesColor.primary)
                }

                Button {
                    runCommand(title: String(localized: "安装 Core Profile"), command: "/bin/sh /usr/local/bin/ogent-agent profile-install core", timeout: 300)
                } label: {
                    actionLabel("tray.and.arrow.down.fill", String(localized: "安装 Core Profile"), color: OasesColor.emerald)
                }

                Button {
                    runCommand(title: String(localized: "安装 12306 MCP Profile"), command: "/bin/sh /usr/local/bin/ogent-agent profile-install 12306", timeout: 300)
                } label: {
                    actionLabel("point.3.connected.trianglepath.dotted", String(localized: "安装 12306 MCP Profile"), color: OasesColor.emerald)
                }

                Button {
                    runCommand(title: String(localized: "安装 Local Model Profile"), command: "/bin/sh /usr/local/bin/ogent-agent profile-install local-model", timeout: 600)
                } label: {
                    actionLabel("terminal.fill", String(localized: "安装 Local Model Profile"), color: OasesColor.emerald)
                }
            } header: {
                Text("工程 Profile")
            } footer: {
                Text("Rootfs Doctor 会汇总 iSH/Ogent runtime、目录、核心命令和 profile 状态；Rootfs Repair 会重建运行目录并修复 Core Profile。Profile 会把常用依赖一次性部署进 iSH rootfs，避免工程任务中反复尝试 apk add。12306 MCP Profile 会安装 nodejs/npm/npx；Local Model Profile 会安装构建 llama.cpp 和下载 GGUF 所需依赖，但仍需要可执行的 llama-server 和 GGUF 模型文件。")
            }
            .disabled(isBusy)

            if !commandOutput.isEmpty {
                Section("输出") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(commandOutput)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OasesColor.foreground)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section("操作") {
                Button {
                    createSnapshot()
                } label: {
                    actionLabel("archivebox.fill", String(localized: "创建 Rootfs 快照"), color: .indigo)
                }
                .disabled(isBusy || !status.installed)

                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    actionLabel("arrow.clockwise", String(localized: "重置并备份用户数据"), color: .orange)
                }
                .disabled(isBusy)
            }

            if let message {
                Section {
                    Text(message)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.emerald)
                        .textSelection(.enabled)
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.oasesCaption())
                        .foregroundStyle(OasesColor.destructive)
                        .textSelection(.enabled)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Rootfs 管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新") { refreshStatus() }
                    .disabled(isBusy)
            }
        }
        .confirmationDialog(
            "重置 Rootfs 会恢复内置 Alpine 镜像。运行中的沙箱会在下次启动时执行重置。",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置并备份用户数据", role: .destructive) {
                resetRootfs()
            }
            Button("取消", role: .cancel) {}
        }
        .task {
            refreshStatus()
        }
    }

    private func refreshStatus() {
        status = ISHRootfsManager.status()
    }

    private func createSnapshot() {
        isBusy = true
        message = nil
        errorMessage = nil
        Task.detached {
            do {
                let url = try ISHRootfsManager.createSnapshot()
                await MainActor.run {
                    isBusy = false
                    status = ISHRootfsManager.status()
                    message = String(localized: "Rootfs 快照已创建：\(url.path)")
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func resetRootfs() {
        isBusy = true
        message = nil
        errorMessage = nil
        Task.detached {
            do {
                let result = try ISHRootfsManager.resetRootfsBackingUpUserData()
                await MainActor.run {
                    isBusy = false
                    status = ISHRootfsManager.status()
                    var text = result.message
                    if let backup = result.backupURL {
                        text += "\n" + String(localized: "备份：\(backup.path)")
                    }
                    if result.requiresRestart {
                        text += "\n" + String(localized: "请完全退出并重新打开 App 后生效。")
                    }
                    message = text
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func runCommand(title: String, command: String, timeout: TimeInterval) {
        guard let shell = ToolRegistry.shared.tool(named: "shell_execute") else {
            errorMessage = String(localized: "shell_execute 未注册。")
            return
        }
        isBusy = true
        message = nil
        errorMessage = nil
        commandOutput = "$ \(command)\n"

        Task {
            do {
                let payload: [String: Any] = ["command": command, "timeout": timeout]
                let data = try JSONSerialization.data(withJSONObject: payload)
                let json = String(data: data, encoding: .utf8) ?? "{}"
                let result = try await shell.invoke(argumentsJSON: json, onProgress: { _ in })
                await MainActor.run {
                    isBusy = false
                    refreshStatus()
                    commandOutput += result.text ?? String(localized: "\(title) 完成。")
                }
            } catch {
                await MainActor.run {
                    isBusy = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    @ViewBuilder
    private func statusRow(_ icon: String, _ title: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .center, spacing: OasesSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color))
            Text(title)
                .font(.oasesBodyBold())
                .foregroundStyle(OasesColor.foreground)
            Spacer(minLength: OasesSpacing.sm)
            Text(detail)
                .font(.oasesBody())
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionLabel(_ icon: String, _ title: String, color: Color) -> some View {
        HStack(spacing: OasesSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(color))
            Text(title)
                .font(.oasesBodyBold())
        }
    }

    private func compactPath(_ path: String) -> String {
        guard path.count > 42 else { return path }
        return "…" + path.suffix(42)
    }

    private var rootfsProbeCommand: String {
        """
        printf '## Alpine\\n'
        cat /etc/alpine-release 2>/dev/null || true
        printf '\\n## apk\\n'
        apk --version 2>&1 || true
        printf '\\nrepositories:\\n'
        cat /etc/apk/repositories 2>/dev/null || true
        printf '\\n## runtimes\\n'
        for bin in python3 pip3 node npm git curl wget; do
          if command -v "$bin" >/dev/null 2>&1; then
            printf '%s=%s\\n' "$bin" "$(command -v "$bin")"
          else
            printf '%s=missing\\n' "$bin"
          fi
        done
        printf '\\n## disk\\n'
        df -h / 2>/dev/null || true
        """
    }
}

private struct RootfsFileEntry: Identifiable, Equatable {
    let id: String
    let name: String
    let url: URL
    let isDirectory: Bool
    let sizeLabel: String
}

struct RootfsBrowserView: View {
    let url: URL
    let guestPath: String
    @State private var entries: [RootfsFileEntry] = []
    @State private var previewPath: String?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.destructive)
            }
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        RootfsBrowserView(url: entry.url, guestPath: childPath(entry.name))
                    } label: {
                        fileRow(entry)
                    }
                } else {
                    Button {
                        previewPath = entry.url.path
                    } label: {
                        fileRow(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(guestPath)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .onAppear(perform: loadEntries)
        .sheet(isPresented: Binding(
            get: { previewPath != nil },
            set: { if !$0 { previewPath = nil } }
        )) {
            if let previewPath {
                ToolFilePreviewSheet(filePath: previewPath)
            }
        }
    }

    private func loadEntries() {
        do {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey]
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: []
            )
            entries = urls.map { item in
                let values = try? item.resourceValues(forKeys: Set(keys))
                let isDirectory = values?.isDirectory == true
                let bytes = Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                return RootfsFileEntry(
                    id: item.path,
                    name: item.lastPathComponent,
                    url: item,
                    isDirectory: isDirectory,
                    sizeLabel: isDirectory ? String(localized: "文件夹") : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory && !$1.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            errorMessage = nil
        } catch {
            entries = []
            errorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private func fileRow(_ entry: RootfsFileEntry) -> some View {
        HStack(spacing: OasesSpacing.sm) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                .font(.system(size: 16))
                .foregroundStyle(entry.isDirectory ? OasesColor.primary : OasesColor.mutedForeground)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.oasesBody())
                    .foregroundStyle(OasesColor.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.sizeLabel)
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .padding(.vertical, 2)
    }

    private func childPath(_ name: String) -> String {
        if guestPath == "/" { return "/" + name }
        return guestPath + "/" + name
    }
}
