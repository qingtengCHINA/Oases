import SwiftUI

/// Sonner-equivalent: a top-anchored toast that slides in, auto-dismisses, and
/// surfaces localized error context instead of a raw `⚠️ <message>` bubble.
struct ErrorBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OasesColor.destructive)
                .accessibilityHidden(true)
            Text(message)
                .font(.custom(OasesTypography.serif, size: 13, relativeTo: .footnote))
                .foregroundStyle(OasesColor.foreground)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OasesColor.card.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(OasesColor.border.opacity(0.7), lineWidth: 0.5)
        )
        .oasesShadow(.overlay)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        // The banner appears without taking focus, so VoiceOver users never
        // learned that a send failed. Announce it when it appears and when
        // the text changes while it stays up.
        .onAppear { Self.announce(message) }
        .onChange(of: message) { _, newMessage in Self.announce(newMessage) }
    }

    private static func announce(_ message: String) {
        var announcement = AttributedString(message)
        // High priority: don't let the next focus change cut the error off.
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }
}

/// Maps a streaming error into localized, human-readable copy (mirrors Web's
/// error toast tone rather than dumping `error.localizedDescription`).
enum ChatErrorCopy {
    static func message(for error: Error) -> String {
        // Limited mode: say what is actually needed instead of "try again" —
        // retrying can't succeed until the user agrees to AI data sharing.
        if AIDataSharingConsent.isConsentError(error) {
            return String(localized: "需要先同意 AI 数据共享，才能发送给 AI。", comment: "Chat error banner: the message was not sent because AI data sharing is off (limited mode)")
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case URLError.notConnectedToInternet.rawValue,
                 URLError.cannotFindHost.rawValue,
                 URLError.cannotConnectToHost.rawValue,
                 URLError.timedOut.rawValue,
                 URLError.networkConnectionLost.rawValue:
                return String(localized: "网络不可用，请检查连接后重试。")
            case URLError.cancelled.rawValue:
                return String(localized: "已停止生成。")
            default:
                return String(localized: "网络异常，请稍后重试。")
            }
        }
        if let apiError = error as? APIError {
            switch apiError {
            case .badStatus(let code, let body) where (code == 401 || code == 403) && gatewayCode(body) != nil:
                return gatewayRefusal(gatewayCode(body) ?? "")
            case .badStatus(_, let body) where isQuotaError(body):
                return String(localized: "模型服务额度不足，本地结果已保留。")
            case .badStatus(let code, _) where code == 401 || code == 403:
                return String(localized: "服务鉴权不可用，请检查配置后重试。")
            case .badStatus(let code, _) where code == 402:
                return String(localized: "模型额度不足，请稍后再试或换一个图像模型。")
            case .badStatus(let code, _) where code == 429:
                return String(localized: "请求过于频繁，请稍候片刻再试。")
            case .badStatus(let code, _) where (500..<600).contains(code):
                return String(localized: "服务繁忙，请稍后重试。")
            default:
                return String(localized: "出错了，请重试一次。")
            }
        }
        return String(localized: "出错了，请重试一次。")
    }

    static func projectMessage(for error: Error) -> String {
        let base = message(for: error)
        let route = AIProviderRouting.projectRoute
        guard isModelServiceError(error) else { return base }
        if route != nil {
            return String(localized: "\(base) 本机工具结果已保留；请检查工程模式 AI Provider 的 endpoint、API Key 或额度。", comment: "%@ is the preceding error sentence")
        }
        return String(localized: "\(base) 本机工具结果已保留；工程执行层仍在本机，请稍后重试模型请求。", comment: "%@ is the preceding error sentence")
    }

    /// The Oases gateway's refusal code (`{"error":{"code":"model_not_allowed"}}`),
    /// for the refusals the copy can say something specific about.
    private static func gatewayCode(_ body: String?) -> String? {
        guard let data = body?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let code = error["code"] as? String else { return nil }
        let known: Set<String> = [
            "model_not_allowed", "model_denied", "provider_denied", "provider_unknown",
            "attestation_required", "attestation_failed",
            "key_disabled", "key_expired", "quota_exhausted"
        ]
        return known.contains(code) ? code : nil
    }

    private static func gatewayRefusal(_ code: String) -> String {
        switch code {
        case "model_not_allowed", "model_denied", "provider_denied", "provider_unknown":
            return String(localized: "这个模型暂未对 Oases Chat 开放，请换一个模型。", comment: "Chat error: the Oases gateway does not let this app's key use the picked model")
        case "attestation_required", "attestation_failed":
            return String(localized: "设备认证没有通过，请稍后重试。", comment: "Chat error: App Attest check failed on the Oases gateway")
        case "quota_exhausted":
            return String(localized: "模型服务额度不足，本地结果已保留。")
        default:
            return String(localized: "服务鉴权不可用，请检查配置后重试。")
        }
    }

    private static func isQuotaError(_ body: String?) -> Bool {
        guard let body = body?.lowercased() else { return false }
        return body.contains("insufficient")
            || body.contains("quota")
            || body.contains("balance")
            || body.contains("billing")
            || body.contains("credits")
    }

    private static func isModelServiceError(_ error: Error) -> Bool {
        guard let apiError = error as? APIError else { return false }
        switch apiError {
        case .badStatus:
            return true
        default:
            return false
        }
    }
}
