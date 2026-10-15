import SwiftUI
import UIKit

/// The design tokens of own.audio's apps: the audiobook brown as the accent, Apple-like
/// neutrals, one spacing scale, a few radii, no shadows — depth comes from materials.
enum Theme {
    enum Colors {
        static let background = Color(light: 0xFFFFFF, dark: 0x000000)
        static let backgroundAlt = Color(light: 0xF7F7F8, dark: 0x0C0C0E)
        static let card = Color(light: 0xFFFFFF, dark: 0x131316)
        static let foreground = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
        static let muted = Color(light: 0x6E6E73, dark: 0x98989D)
        static let border = Color(light: 0xE5E5E7, dark: 0x1D1D1F)
        /// The audiobook brown, the same value as the `AccentColor` asset.
        static let accent = Color(light: 0x7A4A2B, dark: 0xD7A97C)
        static let success = Color(light: 0x1E8E3E, dark: 0x30D158)
        static let error = Color(light: 0xC41E3A, dark: 0xFF453A)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let screenEdge: CGFloat = 16
    }

    enum Radius {
        static let card: CGFloat = 12
        static let cover: CGFloat = 12
        static let miniPlayer: CGFloat = 16
        static let sheetTop: CGFloat = 28
    }

    /// Apple's minimum touch target.
    static let minTarget: CGFloat = 44
    static let coverCrossfade: Double = 0.2
}

extension Color {
    /// A dynamic colour from a light and a dark hex value.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

extension View {
    /// An animation that is dropped when Reduce Motion is on, so the state still changes but
    /// nothing moves.
    func accessibleAnimation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(AccessibleAnimation(animation: animation, value: value))
    }
}

private struct AccessibleAnimation<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation?
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

enum Haptics {
    @MainActor static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }

    @MainActor static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

/// "3:07", or "1:02:07" past an hour.
func formatDuration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let hours = total / 3600
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}
