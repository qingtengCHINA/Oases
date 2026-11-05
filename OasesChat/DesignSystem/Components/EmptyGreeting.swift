import SwiftUI

/// Shared empty-state greeting for every mode — the layout is identical
/// across modes; only the `MetallicGlyph` tint changes per `AppMode`
/// (text → pink, audio → red, image → blue, project → iridescent purple).
///
/// The greeting refreshes across conversations: each new empty state picks a
/// fresh random line from the current time-of-day pool (mirrors Web's
/// per-conversation `getEmptyStateGreeting`).
struct EmptyGreeting: View {
    var mode: AppMode = .chat
    var line: String? = nil

    @State private var resolvedLine: String = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MetallicGlyph(size: 52, variant: .greeting, mode: mode)
                .padding(.top, 2)

            // Web `.empty-greeting-text`: serif, ~30pt on mobile, foreground
            // colour. The horizontal shimmer mask was removed — it gated text
            // visibility behind an animation cycle and the request was to drop
            // the shiny effect entirely on the iOS port. The text frame is
            // generous so long greetings breathe instead of wrapping into a
            // narrow column.
            Text(resolvedLine)
                .font(.custom(OasesTypography.serif, size: 30, relativeTo: .title))
                .fontWeight(.medium)
                .foregroundStyle(OasesColor.foreground)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .onAppear { refreshLine() }
    }

    /// Pick a fresh greeting when the empty state appears — gives variety
    /// across new conversations (Web refreshes per conversation id).
    private func refreshLine() {
        if let line, !line.isEmpty {
            resolvedLine = line
        } else {
            resolvedLine = GreetingCopy.randomLine()
        }
    }
}

#Preview {
    VStack(spacing: 32) {
        ForEach(AppMode.allCases) { mode in
            EmptyGreeting(mode: mode, line: "中午好。先吃饭还是先开工？") // i18n-ignore: preview sample
        }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(OasesColor.background)
    .preferredColorScheme(.dark)
}
