import SwiftUI

/// Small pill button used by `TerminalKeyboardAccessory`.
///
/// In OpenMinis this lives at the bottom of `Views/Rootfs/ISHTerminalView.swift`,
/// but it is a plain reusable control with no dependency on that view — the
/// keyboard accessory is its only caller.

struct QuickCommandButton: View {
    let label: String
    let icon: String
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.blue : Color(white: 0.25))
            .foregroundColor(isActive ? .white : .green)
            .cornerRadius(6)
        }
    }
}
