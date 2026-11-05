import SwiftUI

struct OffloadPermissionSettingsView: View {
    @ObservedObject private var manager = OffloadPermissionManager.shared
    @ObservedObject private var configGate = OasesConfigPermissionStore.shared
    @ObservedObject private var correctionConsent = VoiceCorrectionCollectionConsent.shared
    @State private var showClearCorrectionConfirm = false
    @State private var correctionDataCleared = false
    @State private var confirmSetAllBypass = false

    var body: some View {
        List {
            Section("Background") {
                NavigationLink {
                    EnhancedBackgroundSettingsView()
                } label: {
                    Label("Background", systemImage: "location.circle.fill")
                }
                NavigationLink {
                    AutomationPermissionSettingsView()
                } label: {
                    Label(SettingsCopy.t("自动化", "Automation"), systemImage: "clock.arrow.2.circlepath")
                }
            }

            Section {
                Toggle("Allow oases-config", isOn: $configGate.enabled)
            } header: {
                Text("Configuration Tool")
            } footer: {
                Text("When disabled, the agent cannot read or modify any settings via oases-config. The change history at Logs → Config Changes remains accessible. The agent will receive a permission_denied error and can guide you via deep links instead.")
            }

            Section {
                ForEach(settingsCommands, id: \.name) { cmd in
                    CommandPermissionRow(command: cmd)
                }
            } header: {
                Text("Privacy")
            } footer: {
                // Ask Once is per action, not per command: say so where it is chosen.
                Text("「询问一次」按操作分别询问：同一会话内允许过的操作不再询问，其他操作仍会单独询问；删除每次都会询问。")
            }

            Section {
                Toggle(String(localized: "Collect voice correction data",
                              comment: "Permissions: toggle for voice-correction learning data collection"),
                       isOn: $correctionConsent.isEnabled)
                Button(role: .destructive) {
                    showClearCorrectionConfirm = true
                } label: {
                    Label(String(localized: "Clear Collected Data",
                                 comment: "Permissions: wipe voice-correction learning data"),
                          systemImage: "trash")
                }
            } header: {
                Text("Voice Correction Learning")
            } footer: {
                Text("When enabled, your manual fixes to voice transcripts (original → corrected pairs), accepted/rejected AI corrections, and frequently typed terms are stored in a local on-device database to make future voice corrections smarter. Nothing is uploaded. Default is off; existing data stays until you clear it.")
            }
            .confirmationDialog(
                String(localized: "Clear all collected voice correction data?",
                       comment: "Permissions: confirm wipe of correction learning data"),
                isPresented: $showClearCorrectionConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "Clear All", comment: "Confirm clearing correction data"),
                       role: .destructive) {
                    Task {
                        if let db = VoiceCorrectionDB.shared {
                            await db.clearTable("confusion_dictionary")
                            await db.clearTable("typed_vocabulary")
                            await db.clearTable("correction_events")
                        }
                        correctionDataCleared = true
                    }
                }
                Button(String(localized: "Cancel", comment: "Cancel"), role: .cancel) {}
            }
            .alert(String(localized: "Voice correction data cleared",
                          comment: "Permissions: wipe done confirmation"),
                   isPresented: $correctionDataCleared) {
                Button("OK") {}
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Set All Bypass") {
                    // Every privacy capability at once, also unattended: asked first, like each
                    // switch on the Automation page.
                    confirmSetAllBypass = true
                }
            }
        }
        .confirmationDialog(
            String(localized: "Allow every capability without asking?", comment: "Permissions: confirm Set All Bypass"),
            isPresented: $confirmSetAllBypass,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Allow All Without Asking", comment: "Permissions: confirm Set All Bypass"), role: .destructive) {
                manager.setAllBypass()
                // The oases-config master switch is a separate
                // store from OffloadPermissionManager (different
                // subsystem) so its own setAllBypass doesn't touch
                // it. Flip it on here so "Set All Bypass" really
                // does enable everything the user can see on this
                // screen.
                configGate.enabled = true
            }
            Button(String(localized: "Cancel", comment: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "The agent could then read your calendar, contacts, photos, location, clipboard and browser cookies, open links and call paid models, also in background automations, without asking you. You can change each one back here.", comment: "Permissions: what Set All Bypass allows"))
        }
    }

    private var settingsCommands: [OffloadCommandInfo] {
        OffloadPermissionManager.allCommands.filter { $0.showInSettings }
    }
}

private struct CommandPermissionRow: View {
    let command: OffloadCommandInfo
    @ObservedObject private var manager = OffloadPermissionManager.shared

    /// Reads and writes the manager directly (no cached copy), so a change
    /// made on the Automation page shows here and vice versa.
    private var level: Binding<OffloadPermissionLevel> {
        Binding(
            get: { manager.permissionLevel(for: command.name) },
            set: { manager.setPermissionLevel($0, for: command.name) }
        )
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.displayLabel)
                Text(command.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: level) {
                ForEach(OffloadPermissionLevel.allCases, id: \.self) { lvl in
                    Text(lvl.displayName).tag(lvl)
                }
            }
            .pickerStyle(.menu)
        }
    }
}
