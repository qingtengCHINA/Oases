import SwiftUI

/// [Stage 1.3] MCP management entry. The full server list / import UI still
/// lives inside `AgentSettingsView` (Settings → 工程模式与 MCP); this view is
/// the Stage-1 landing pad so navigation can already point at
/// `Features/MCP/` and Stage 2 can migrate the body out of Settings without
/// another directory reshuffle.
struct MCPManagementView: View {
    var body: some View {
        List {
            Section {
                NavigationLink {
                    AgentSettingsView()
                } label: {
                    Label("打开工程模式与 MCP", systemImage: "point.3.connected.trianglepath.dotted")
                }
            } footer: {
                Text("MCP server 列表、12306 MCP 安装与 Claude Desktop JSON 导入目前仍在「工程模式与 MCP」页。Stage 2 会把 MCP 段完整搬到本模块。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("MCP")
        .navigationBarTitleDisplayMode(.inline)
    }
}
