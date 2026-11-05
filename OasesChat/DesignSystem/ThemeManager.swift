import SwiftUI

@Observable
final class ThemeManager {
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return String(localized: "跟随系统", comment: "Theme mode")
            case .light: return String(localized: "明亮", comment: "Theme mode")
            case .dark: return String(localized: "暗黑", comment: "Theme mode")
            }
        }
    }

    var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey) }
    }

    init() {
        // Dark is the product default. A stored choice still wins, including
        // an explicit "follow the system" selection made in Settings.
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? Mode.dark.rawValue
        self.mode = Mode(rawValue: raw) ?? .dark
    }

    var colorScheme: ColorScheme? {
        switch mode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    private static let storageKey = "OasesChat.themeMode"
}
