import ActivityKit
import SwiftUI
import WidgetKit

/// A small breathing orb in Oases colours for the Live Activity while the model thinks.
///
/// Widgets can't animate continuously, so the orb's pose (where its three soft blobs sit, how
/// large they are, how it turns) is a function of `pulse`, which the app bumps on every
/// background heartbeat; the system eases from one pose to the next.
@available(iOSApplicationExtension 16.2, *)
struct ThinkingOrb: View {
    let pulse: Int
    var phase: String = "thinking"
    var size: CGFloat = 18

    private var colors: [Color] {
        switch phase {
        case "tool":
            return [Color(red: 1.0, green: 0.78, blue: 0.42), Color(red: 0.42, green: 0.91, blue: 0.67), Color(red: 0.98, green: 0.95, blue: 0.86)]
        case "answering":
            return [Color(red: 0.56, green: 0.96, blue: 0.72), Color(red: 0.38, green: 0.77, blue: 0.96), Color(red: 0.90, green: 0.98, blue: 0.94)]
        default:
            return [Color(red: 0.63, green: 0.54, blue: 1.0), Color(red: 0.44, green: 0.89, blue: 0.84), Color(red: 0.93, green: 0.92, blue: 1.0)]
        }
    }

    var body: some View {
        let t = Double(pulse)
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                let phaseShift = Double(i) * 2.1
                let dx = cos(t * 1.7 + phaseShift) * 0.18
                let dy = sin(t * 1.3 + phaseShift * 0.8) * 0.18
                let scale = 0.62 + 0.16 * sin(t * 1.1 + phaseShift)
                Circle()
                    .fill(colors[i])
                    .frame(width: size * scale, height: size * scale)
                    .offset(x: size * dx, y: size * dy)
                    .blur(radius: size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(t * 37))
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .animation(.easeInOut(duration: 1.8), value: pulse)
        .accessibilityHidden(true)
    }
}

/// The island's thinking line: orb, what the model is doing, and how long it has been at it.
/// Stale (the app was suspended) reads "Paused".
@available(iOSApplicationExtension 16.2, *)
struct ThinkingStatusRow: View {
    let state: AgentActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isStale {
                Image(systemName: "pause.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            } else {
                ThinkingOrb(pulse: state.pulse, phase: state.thinkingPhase, size: 22)
            }
            Text(isStale ? String(localized: "已暂停 · 打开 App 继续", comment: "Live Activity: the app was suspended while the model was thinking") : state.phaseLabel)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .contentTransition(.interpolate)
            Spacer(minLength: 6)
            if !isStale, let started = state.phaseStartedAt {
                Text(timerInterval: started...Date.distantFuture, countsDown: false)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }
}

@available(iOSApplicationExtension 16.2, *)
extension AgentActivityAttributes.ContentState {
    /// A run is live and the island should show the thinking look.
    var isThinking: Bool { !thinkingPhase.isEmpty && !allCompleted }
}
