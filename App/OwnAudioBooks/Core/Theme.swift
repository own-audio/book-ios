import SwiftUI
import UIKit

/// The few layout constants shared across screens.
enum Theme {
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
        static let cover: CGFloat = 8
        static let miniPlayer: CGFloat = 14
    }

    /// Apple's minimum touch target.
    static let minTarget: CGFloat = 44
    static let coverCrossfade: Double = 0.3
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
