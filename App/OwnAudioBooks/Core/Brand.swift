import SwiftUI

// The own.audio brand on screen: the mark, the wordmark and the hero. These are own.audio's
// (see TRADEMARK.md in the server repository): a fork of this app uses its own.

/// The own.audio mark: a pulsing core, two slowly spinning arcs, and five dancers waltzing
/// around it — the construction of the app icon, in motion. `tribe` is own.audio itself (one
/// dancer per product in its colour); `init(size:accent:)` is this app speaking, every dot in
/// the audiobook brown. Below 24 pt the choreography stops being legible and six static dots
/// stand in.
struct OwnAudioMark: View {
    private let size: CGFloat
    private let colors: [Color]
    private let core: Color
    private static let compactThreshold: CGFloat = 24
    private static let dancerAngles: [Double] = [0, 72, 144, 216, 288]
    @State private var isAnimating = false

    init(size: CGFloat = 64, accent: Color = Theme.Colors.accent) {
        self.size = size
        colors = [accent]
        core = accent
    }

    private init(size: CGFloat, colors: [Color], core: Color) {
        self.size = size
        self.colors = colors
        self.core = core
    }

    static func tribe(size: CGFloat = 64) -> OwnAudioMark {
        OwnAudioMark(
            size: size,
            colors: [
                Color(light: 0x8A6100, dark: 0xFABB05), // book
                Color(light: 0x0A6E9C, dark: 0x29ABE2), // podcast
                Color(light: 0xC42B21, dark: 0xFF6B61), // music
                Color(light: 0x1E7A3C, dark: 0x34C759), // creator
                Color(light: 0x6E44FF, dark: 0x9B7BFF), // family
            ],
            core: Color(light: 0x6E44FF, dark: 0x9B7BFF)
        )
    }

    var body: some View {
        let unit = size / 100
        ZStack {
            if size >= Self.compactThreshold {
                arcs(unit: unit)
                dancers(unit: unit)
            } else {
                compactDots(unit: unit)
            }
            Circle()
                .fill(core)
                .frame(width: 22 * unit, height: 22 * unit)
                .scaleEffect(isAnimating ? 1.24 : 1)
                .accessibleAnimation(.timingCurve(0.21, 0.98, 0.6, 0.99, duration: 0.42).repeatForever(autoreverses: true), value: isAnimating)
        }
        .frame(width: size, height: size)
        .onAppear { isAnimating = true }
        .accessibilityHidden(true)
    }

    private func arcs(unit: CGFloat) -> some View {
        ZStack {
            Circle()
                .trim(from: 0.14, to: 0.86)
                .stroke(Theme.Colors.muted, style: StrokeStyle(lineWidth: 3.5 * unit, lineCap: .round))
                .frame(width: 40 * unit, height: 40 * unit)
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.16, to: 0.84)
                .stroke(Theme.Colors.muted.opacity(0.6), style: StrokeStyle(lineWidth: 2.5 * unit, lineCap: .round))
                .frame(width: 60 * unit, height: 60 * unit)
                .rotationEffect(.degrees(90))
        }
        .rotationEffect(.degrees(isAnimating ? 360 : 0))
        .accessibleAnimation(.linear(duration: 7).repeatForever(autoreverses: false), value: isAnimating)
    }

    private func dancers(unit: CGFloat) -> some View {
        ZStack {
            ForEach(Array(Self.dancerAngles.enumerated()), id: \.offset) { index, angle in
                dancer(unit: unit, color: colors[index % colors.count]).rotationEffect(.degrees(angle))
            }
        }
        .frame(width: size, height: size)
        .rotationEffect(.degrees(isAnimating ? 8 : -8))
        .scaleEffect(isAnimating ? 1.02 : 0.98)
        .accessibleAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: isAnimating)
    }

    /// One dancer: a head and two hands, the icon's three-dot cluster.
    private func dancer(unit: CGFloat, color: Color) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 10 * unit, height: 10 * unit).offset(y: -36 * unit)
            Circle().fill(color).frame(width: 5 * unit, height: 5 * unit).offset(x: -8.5 * unit, y: -35 * unit)
            Circle().fill(color).frame(width: 5 * unit, height: 5 * unit).offset(x: 8.5 * unit, y: -35 * unit)
        }
        .frame(width: size, height: size)
    }

    private func compactDots(unit: CGFloat) -> some View {
        ZStack {
            ForEach(Array(Self.dancerAngles.enumerated()), id: \.offset) { index, angle in
                Circle().fill(colors[index % colors.count]).frame(width: 9 * unit, height: 9 * unit).offset(y: -36 * unit).rotationEffect(.degrees(angle))
            }
        }
        .frame(width: size, height: size)
    }
}

/// "own." with a slot that cycles through what own.audio is for.
struct RotatingWordmark: View {
    static let defaultWords = ["audio", "book", "family", "story", "chapter", "voice", "night", "road"]
    private let words: [String]
    private let interval: Duration
    @State private var index = 0

    init(words: [String] = RotatingWordmark.defaultWords, interval: Duration = .seconds(1.8)) {
        self.words = words
        self.interval = interval
    }

    var body: some View {
        HStack(spacing: 2) {
            Text(verbatim: "own").foregroundStyle(Theme.Colors.foreground)
            Text(verbatim: ".").foregroundStyle(Theme.Colors.accent)
            // Every word is stacked invisibly so the slot keeps the widest one's width and
            // "own." never shifts.
            ZStack(alignment: .leading) {
                ForEach(words, id: \.self) { Text(verbatim: $0).opacity(0) }
                Text(verbatim: words[index])
                    .foregroundStyle(Theme.Colors.muted)
                    .id(index)
                    .transition(.asymmetric(insertion: .offset(y: 16).combined(with: .opacity), removal: .offset(y: -16).combined(with: .opacity)))
                    .accessibleAnimation(.timingCurve(0.77, 0, 0.175, 1, duration: 0.6), value: index)
            }
        }
        .font(.system(size: 32, weight: .heavy))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "own.audio"))
        .task {
            guard words.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                index = (index + 1) % words.count
            }
        }
    }
}

/// The full-bleed artwork behind the welcome screen, veiled so the form stays legible. The
/// asset catalog picks the colourway by appearance.
struct HeroBackground: View {
    var body: some View {
        // `Color.clear` takes the proposed size; the image rides in an overlay so its overflow
        // never widens the layout, and is clipped to the screen.
        Color.clear
            .overlay { Image("OwnAudioHero").resizable().scaledToFill() }
            .overlay(Theme.Colors.background.opacity(0.72))
            .clipped()
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Three bars that bounce while playing and rest staggered while paused; stops moving under
/// Reduce Motion but keeps the two poses apart.
struct NowPlayingIndicator: View {
    let isPlaying: Bool
    var accent: Color = Theme.Colors.accent
    @State private var isTall = [false, false, false]
    private static let durations: [Double] = [0.45, 0.62, 0.53]
    private static let resting: [CGFloat] = [6, 10, 7]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(accent)
                    .frame(width: 3, height: isTall[index] ? 12 : Self.resting[index])
                    .accessibleAnimation(
                        isPlaying ? .easeInOut(duration: Self.durations[index]).repeatForever(autoreverses: true).delay(Double(index) * 0.12) : .easeInOut(duration: 0.25),
                        value: isTall[index]
                    )
            }
        }
        .frame(width: 14, height: 12, alignment: .bottom)
        .onAppear { sync() }
        .onChange(of: isPlaying) { _, _ in sync() }
        .accessibilityLabel(isPlaying ? "Playing" : "Paused")
    }

    private func sync() {
        for index in 0..<3 { isTall[index] = isPlaying }
    }
}

/// A section's title, as every list and shelf shows it.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var trailing: (() -> AnyView)? = nil

    var body: some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            trailing?()
        }
        .padding(.horizontal, Theme.Spacing.screenEdge)
    }
}

/// A book shared with the household: the people icon, and never a lock.
struct FamilyBadge: View {
    var body: some View {
        Image(systemName: "person.2.fill")
            .font(.caption2.weight(.semibold))
            .padding(6)
            .background(.ultraThinMaterial, in: Circle())
            .foregroundStyle(Theme.Colors.accent)
            .accessibilityLabel("Shared with family")
    }
}

struct FavouriteBadge: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .padding(5)
            .background(.black.opacity(0.45), in: Circle())
            .accessibilityLabel("Favourite")
    }
}
