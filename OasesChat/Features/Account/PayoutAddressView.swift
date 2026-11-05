import SwiftUI

/// 收币地址: the Arc address future QTC coins would go to. Typed by hand,
/// checked here for shape and by QTC for its checksum; it can be cleared.
/// Arc only (Solana is cancelled); shown only outside mainland China. A
/// grouped form on Settings' background with its raised row colour.
struct PayoutAddressView: View {
    @Environment(AccountStore.self) private var account
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var saving = false
    @State private var problem: Problem?

    private enum Problem {
        /// "地址格式不对，请检查"
        case format
        /// "保存失败，请重试"
        case failed
    }

    private var saved: String? { account.me?.payoutAddresses.arc }
    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField(text: $draft, prompt: Text(verbatim: "0x…").foregroundStyle(AccountStyle.secondaryText.opacity(0.6)), axis: .vertical) {
                    Text(verbatim: "Arc")
                }
                .font(AccountStyle.monoFont(15))
                .foregroundStyle(AccountStyle.text)
                .tint(AccountStyle.tint)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.asciiCapable)
                .submitLabel(.done)
                .onSubmit(save)
                .onChange(of: draft) { problem = nil }
                .listRowBackground(AccountStyle.surface)
            } header: {
                Text(verbatim: "Arc")
                    .font(AccountStyle.font(13, weight: .semibold))
                    .foregroundStyle(AccountStyle.secondaryText)
            } footer: {
                if let problem {
                    Text(problem == .format ? QT("account.payoutErrFormat") : QT("account.payoutErrFailed"))
                        .font(AccountStyle.font(13))
                        .foregroundStyle(AccountStyle.danger)
                }
            }
            if saved != nil {
                Section {
                    Button(role: .destructive) {
                        submit(nil)
                    } label: {
                        Text(QT("account.payoutClear"))
                            .font(AccountStyle.font(16))
                            .foregroundStyle(AccountStyle.danger)
                    }
                    .disabled(saving)
                }
                .listRowBackground(AccountStyle.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AccountStyle.canvas.ignoresSafeArea())
        .accountNavigationTitle(QT("account.payout"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button(action: save) {
                        Text(QT("account.save"))
                            .font(AccountStyle.font(17, weight: .semibold))
                    }
                    .tint(AccountStyle.tint)
                    .disabled(trimmed.isEmpty || trimmed == saved)
                }
            }
        }
        .onAppear { draft = saved ?? "" }
        // The session ended (sign-in shows on the account page underneath).
        .onChange(of: account.isSignedIn) { _, signedIn in
            if !signedIn { dismiss() }
        }
    }

    private func save() {
        guard !saving, !trimmed.isEmpty, trimmed != saved else { return }
        // Checked here first: a wrong shape never reaches the server.
        guard PayoutAddress.isPlausibleArc(trimmed) else {
            problem = .format
            return
        }
        submit(trimmed)
    }

    /// Saves (or, with nil, clears) the address. The task holds only what it
    /// needs, never this page.
    private func submit(_ address: String?) {
        saving = true
        Task { [account, dismiss, saving = $saving, problem = $problem] in
            let outcome = await Self.save(address, account: account)
            saving.wrappedValue = false
            switch outcome {
            case .saved: dismiss()
            case .signedOut: break  // signed out by the store; this page closes
            case .problem(let found): problem.wrappedValue = found
            }
        }
    }

    private enum SaveOutcome {
        case saved
        case signedOut
        case problem(Problem)
    }

    private static func save(_ address: String?, account: AccountStore) async -> SaveOutcome {
        do {
            try await account.savePayoutAddress(address)
            return .saved
        } catch QTCError.invalidAddress {
            return .problem(.format)  // e.g. a mixed-case address whose checksum is wrong
        } catch QTCError.unauthorized {
            return .signedOut
        } catch {
            return .problem(.failed)
        }
    }
}
