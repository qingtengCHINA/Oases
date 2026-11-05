import SwiftUI
import UIKit

/// Whether a recents row is being swiped right now. The drawer reads it so a
/// left swipe on a row deletes that row instead of closing the drawer.
@MainActor
@Observable
final class SidebarRowSwipe {
    static let shared = SidebarRowSwipe()
    var isActive = false
}

/// A row that is deleted only by swiping it all the way to the left. There is
/// no delete button to hit by accident: a short swipe springs back, and only
/// past ~60% of the row's width (felt as a haptic tick) does letting go delete.
struct SwipeToDeleteRow<Content: View>: View {
    let onDelete: () -> Void
    let onTap: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 1
    @State private var axis: Axis?
    @State private var armed = false
    @State private var removing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static var armRatio: CGFloat { 0.6 }

    var body: some View {
        let progress = min(1, -offset / max(1, width * Self.armRatio))
        ZStack(alignment: .trailing) {
            // What is behind the row: grows from the right edge as it slides.
            HStack(spacing: 6) {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .scaleEffect(armed ? 1.15 : 0.85 + 0.15 * progress)
                Text("松手删除", comment: "Sidebar recents: shown behind a row swiped far enough to delete it")
                    .font(.oasesCaptionBold())
                    .opacity(armed ? 1 : 0)
            }
            .foregroundStyle(armed ? Color.white : OasesColor.destructive)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .background(
                RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous)
                    .fill(OasesColor.destructive.opacity(armed ? 0.92 : 0.12 * progress))
            )
            .opacity(offset < -1 ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: armed)

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OasesColor.sidebar.opacity(offset < -1 ? 1 : 0.001))
                .offset(x: offset)
        }
        .clipShape(RoundedRectangle(cornerRadius: OasesRadius.md, style: .continuous))
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .onTapGesture {
            guard offset == 0, !removing else { return }
            onTap()
        }
        .simultaneousGesture(drag)
        .accessibilityAction(named: Text("删除记录", comment: "Sidebar recents: accessibility action that deletes the conversation")) {
            onDelete()
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard !removing else { return }
                if axis == nil {
                    let dx = value.translation.width, dy = value.translation.height
                    axis = (abs(dx) > abs(dy) * 1.2 && dx < 0) ? .horizontal : .vertical
                    if axis == .horizontal { SidebarRowSwipe.shared.isActive = true }
                }
                guard axis == .horizontal else { return }
                // Rubber band past the end: the row never leaves under the finger.
                let raw = min(0, value.translation.width)
                let limit = width * 0.92
                offset = raw > -limit ? raw : -limit - (-raw - limit) * 0.25
                let nowArmed = -offset >= width * Self.armRatio
                if nowArmed != armed {
                    armed = nowArmed
                    if nowArmed {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } else {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                }
            }
            .onEnded { _ in
                defer {
                    axis = nil
                    SidebarRowSwipe.shared.isActive = false
                }
                guard axis == .horizontal, !removing else { return }
                if armed {
                    removing = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(reduceMotion ? .easeOut(duration: 0.1) : .easeIn(duration: 0.18)) {
                        offset = -width - 40
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        onDelete()
                        offset = 0
                        armed = false
                        removing = false
                    }
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) { offset = 0 }
                }
            }
    }
}
