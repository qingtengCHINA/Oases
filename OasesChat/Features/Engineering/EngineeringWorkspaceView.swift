import SwiftUI

/// Oases-owned entry for **Ogent** (engineering / `AppMode.project`).
///
/// Product boundary: RootView only depends on this wrapper. The agent
/// kernel still lives in `EngineeringAgentShell` + `AIChatView` + iSH,
/// but chrome, tint, and empty states follow Oases SwiftUI.
struct EngineeringWorkspaceView: View {
    @Environment(ThemeManager.self) private var theme
    @State private var linuxReady = true

    var body: some View {
        ZStack(alignment: .top) {
            OasesColor.background.ignoresSafeArea()
            EngineeringAgentShell()
            if !linuxReady {
                Text("Linux 环境正在启动，工具调用可能稍后再可用")
                    .font(.caption)
                    .foregroundStyle(OasesColor.mutedForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("oases.code.ish.warming")
            }
        }
        .tint(OasesColor.primary)
        .preferredColorScheme(theme.colorScheme)
        .environmentObject(ShareCoordinator.shared)
        .accessibilityIdentifier("oases.code.engineering.root")
        .accessibilityLabel(Text(OasesBrand.engineeringName))
        .task {
            linuxReady = ISHRuntimeQueue.sync { ish_runtime_is_ready() != 0 }
            guard !linuxReady else { return }
            linuxReady = await Task.detached(priority: .utility) {
                ISHRuntimeQueue.sync { ISHRuntimeBootstrap.bootstrap() }
            }.value
        }
    }
}

#if DEBUG
#Preview("Ogent workspace") {
    EngineeringWorkspaceView()
        .environment(ThemeManager())
}
#endif
