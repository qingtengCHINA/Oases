import SwiftUI
@preconcurrency import WebKit

/// Foreground approval surface for WebKit challenges. The web view is the
/// already-running session, so cookies/local storage and navigation state are
/// preserved when the sheet is dismissed.
struct BrowserApprovalSheet: View {
    let request: BrowserApprovalRequest
    let webView: WKWebView?
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider().overlay(OasesColor.border)
                if let webView {
                    BrowserApprovalWebView(webView: webView)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "浏览器页面不可用",
                        systemImage: "safari",
                        description: Text("请关闭后重新发起网页操作。")
                    )
                }
                actionBar
            }
            .background(OasesColor.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onCancel) {
                        Label("取消", systemImage: "xmark")
                    }
                    .accessibilityLabel("取消浏览器验证")
                }
            }
            .navigationTitle("浏览器确认")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(request.challengeTitle, systemImage: iconName)
                .font(.headline)
                .foregroundStyle(OasesColor.foreground)
            Text(request.title.isEmpty ? request.url : request.title)
                .font(.subheadline)
                .foregroundStyle(OasesColor.mutedForeground)
                .lineLimit(2)
            Text(request.url)
                .font(.caption.monospaced())
                .foregroundStyle(OasesColor.mutedForeground.opacity(0.82))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Label("取消任务", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(OasesColor.mutedForeground)

            Button(action: onApprove) {
                Label("继续", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(OasesColor.primary)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial)
    }

    private var iconName: String {
        switch request.challenge {
        case .login: return "person.crop.circle.badge.checkmark"
        case .captcha: return "checkmark.shield"
        case .payment: return "creditcard"
        case .destructiveAction: return "exclamationmark.triangle"
        }
    }
}

private struct BrowserApprovalWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
