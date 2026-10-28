import SwiftUI

/// The colour the app's buttons, links and highlights take: the app's own brown unless the
/// listener picks another in Settings. The icon and the widgets keep the brown. Copied from
/// own.audio Music, with pink in the list where brown, the app's own colour here, was.
enum AccentChoice: String, CaseIterable, Identifiable {
    case app, blue, indigo, purple, pink, red, orange, yellow, green, teal, graphite

    static let storageKey = "accentColor"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .app: Color("AccentColor")
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .graphite: .gray
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .app: "App Colour"
        case .blue: "Blue"
        case .indigo: "Indigo"
        case .purple: "Purple"
        case .pink: "Pink"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .teal: "Teal"
        case .graphite: "Graphite"
        }
    }

    static var current: AccentChoice {
        AccentChoice(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .app
    }
}

/// Settings → Accent Colour: a row of swatches, the chosen one ringed.
struct AccentColorPicker: View {
    @AppStorage(AccentChoice.storageKey) private var stored: AccentChoice = .app
    /// What the ring shows. Drawn from `stored` alone, the ring followed the first change and
    /// then stayed on it (iOS 27), while the colour itself changed on.
    @State private var choice = AccentChoice.current

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                ForEach(AccentChoice.allCases) { option in
                    Button {
                        Haptics.selection()
                        choice = option
                        stored = option
                    } label: {
                        Circle()
                            .fill(option.color)
                            .frame(width: 32, height: 32)
                            .padding(4)
                            .overlay(Circle().strokeBorder(option == choice ? Color.primary : .clear, lineWidth: 2))
                            .frame(minWidth: Theme.minTarget, minHeight: Theme.minTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(option.title))
                    .accessibilityAddTraits(option == choice ? .isSelected : [])
                    .accessibilityIdentifier("settings.accent.\(option.rawValue)")
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        } header: {
            Text("Accent Colour")
        } footer: {
            Text("For buttons, links and what's playing. The icon and the widgets keep the app's colour.")
        }
    }
}
