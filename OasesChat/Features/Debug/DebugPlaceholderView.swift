import SwiftUI

/// [Stage 1.3] Placeholder for Features/Debug.
struct DebugPlaceholderView: View {
    var body: some View {
        List {
            Section {
                Label("Debug RPC / Hang 检测 / Session 模拟器将在阶段 5 接入。", systemImage: "ant")
                    .font(.oasesCaption())
                    .foregroundStyle(OasesColor.mutedForeground)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Debug")
        .navigationBarTitleDisplayMode(.inline)
    }
}
