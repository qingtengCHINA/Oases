import Combine
import SwiftUI
import UIKit

/// Installs `OffloadPermissionPresenter`. Kept as a modifier so existing call
/// sites (`AIChatView`, `RootView`) stay one line.
struct OffloadPermissionDialogModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.onAppear { OffloadPermissionPresenter.shared.install() }
    }
}

/// Shows offload "Ask Once" prompts from a dedicated top-level window.
///
/// The handler-level gate can ask from any surface — chat mode, the terminal,
/// an automation while another sheet is up. A `.sheet` on a single view could
/// only appear while that view was on screen and nothing else was presented,
/// so prompts elsewhere timed out after 30 s and the command was denied.
@MainActor
final class OffloadPermissionPresenter {
    static let shared = OffloadPermissionPresenter()

    private var subscription: AnyCancellable?
    private var window: UIWindow?
    private var presentedRequestId: String?

    private init() {}

    func install() {
        guard subscription == nil else { return }
        subscription = OffloadPermissionManager.shared.$pendingRequest
            .receive(on: RunLoop.main)
            .sink { [weak self] request in self?.update(request) }
    }

    private func update(_ request: PermissionRequest?) {
        guard let request else {
            tearDown()
            return
        }
        guard request.id != presentedRequestId else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            // No visible scene: the manager's timeout denies the request.
            return
        }

        let host = UIHostingController(rootView: OffloadPermissionDialogContent(request: request))
        host.modalPresentationStyle = .pageSheet
        host.isModalInPresentation = true
        if let sheet = host.sheetPresentationController {
            // Both detents — long arg lists would otherwise push the Allow /
            // Deny buttons below the medium detent; the content scrolls.
            sheet.detents = [.medium(), .large()]
        }

        let present = { [weak self] in
            guard let self else { return }
            let window = self.window ?? UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            if window.rootViewController == nil {
                let root = UIViewController()
                root.view.backgroundColor = .clear
                window.rootViewController = root
            }
            window.isHidden = false
            self.window = window
            self.presentedRequestId = request.id
            window.rootViewController?.present(host, animated: true)
        }
        if let presented = window?.rootViewController?.presentedViewController {
            presented.dismiss(animated: false, completion: present)
        } else {
            present()
        }
    }

    private func tearDown() {
        presentedRequestId = nil
        guard let window else { return }
        if let presented = window.rootViewController?.presentedViewController {
            presented.dismiss(animated: true) { [weak self] in
                guard self?.presentedRequestId == nil else { return }
                window.isHidden = true
            }
        } else {
            window.isHidden = true
        }
    }
}

private struct OffloadPermissionDialogContent: View {
    let request: PermissionRequest

    var body: some View {
        VStack(spacing: 0) {
            // Scrollable content. Long argument lists previously stretched the
            // outer VStack past the sheet height and pushed the Allow / Deny
            // buttons below the bottom edge with no way to scroll to them.
            // Pinning the buttons in a separate sibling and wrapping the rest
            // in a ScrollView guarantees the action row is always visible.
            ScrollView {
                VStack(spacing: 0) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 36))
                            .foregroundStyle(.orange)

                        Text("Permission Request")
                            .font(.title3.bold())

                        Text("The agent wants to use **\(request.commandName)**")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 16)

                    // Description
                    if !request.description.isEmpty {
                        Text(request.description)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                    }

                    // Arguments
                    let args = request.parsedArguments
                    if !args.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(args.enumerated()), id: \.offset) { idx, arg in
                                HStack {
                                    Text(arg.key)
                                        .font(.footnote.bold())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 80, alignment: .trailing)
                                    Text(arg.value)
                                        .font(.footnote.monospaced())
                                        .lineLimit(2)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                if idx < args.count - 1 {
                                    Divider().padding(.leading, 108)
                                }
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                    }

                    // What the approval covers: grants are per action, so a
                    // read approved here does not cover a later delete.
                    Text(scopeNote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }
            }

            // Buttons — pinned to the bottom of the sheet, outside the
            // ScrollView, so they stay tappable even with very long arg lists.
            VStack(spacing: 10) {
                Button {
                    OffloadPermissionManager.shared.respond(to: request.id, allowed: true)
                } label: {
                    Text(request.asksEveryTime
                         ? String(localized: "仅允许这一次", comment: "Permission prompt: allow button for an irreversible action that is asked every time")
                         : String(localized: "Allow in Session"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    OffloadPermissionManager.shared.respond(to: request.id, allowed: false)
                } label: {
                    Text(request.asksEveryTime
                         ? String(localized: "拒绝", comment: "Permission prompt: deny button for an irreversible action that is asked every time")
                         : String(localized: "Deny in Session"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }

    private var scopeNote: String {
        if request.asksEveryTime {
            return String(localized: "删除无法撤销，每次都会单独询问。", comment: "Permission prompt: note under an irreversible action (delete) that is never remembered")
        }
        if request.action.isEmpty {
            return String(localized: "允许后，本会话内同样的操作不再询问。", comment: "Permission prompt: what an approval covers when the command has no action")
        }
        return String(localized: "允许后，本会话内再次执行“\(request.action)”不再询问；其他操作仍会单独询问。", comment: "Permission prompt: what an approval covers. The placeholder is the action (subcommand), e.g. list, create")
    }
}

extension View {
    func offloadPermissionDialog() -> some View {
        modifier(OffloadPermissionDialogModifier())
    }
}
