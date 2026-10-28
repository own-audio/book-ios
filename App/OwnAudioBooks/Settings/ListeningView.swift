import BookLibrary
import Charts
import SwiftUI

/// What the account has listened to on an own.audio server, from all of own.audio's apps: the
/// time per day, per kind and the most played; for the family's admin, everyone's totals too.
/// Copied from own.audio Music.
struct ListeningView: View {
    @Environment(AppModel.self) private var model
    let serverId: UUID
    @State private var range: StatsRange = .month
    @State private var state: LoadState<ListeningStats> = .loading
    /// nil for anyone but the family's admin.
    @State private var family: [MemberListening]?
    @State private var shared = false
    @State private var isSavingShared = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Period", selection: $range) {
                Text("Week").tag(StatsRange.week)
                Text("Month").tag(StatsRange.month)
                Text("Year").tag(StatsRange.year)
                Text("All").tag(StatsRange.all)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.screenEdge)
            .padding(.vertical, Theme.Spacing.sm)
            .accessibilityIdentifier("listening.range")

            LoadStateView(state: state, retry: { Task { await load() } }) { stats in
                List {
                    summary(stats)
                    if stats.byDay.contains(where: { $0.seconds > 0 }) { chart(stats) }
                    kinds(stats)
                    top(stats)
                    if let family { familySection(family) }
                    if family == nil, stats.statsVisibility != nil { sharing }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("Listening")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: range) { await load() }
    }

    private func summary(_ stats: ListeningStats) -> some View {
        Section {
            LabeledContent("Listened", value: Self.duration(stats.totalSeconds))
                .accessibilityIdentifier("listening.total")
            LabeledContent("Days in a Row", value: stats.streakDays.formatted())
            if stats.completedItems > 0 {
                LabeledContent("Audiobooks Finished", value: stats.completedItems.formatted())
            }
        } footer: {
            Text("From every own.audio app signed in to this account.")
        }
    }

    private func chart(_ stats: ListeningStats) -> some View {
        Section {
            Chart(stats.byDay, id: \.day) { day in
                BarMark(
                    x: .value("Day", Self.date(day.day) ?? .distantPast, unit: .day),
                    y: .value("Minutes", day.seconds / 60)
                )
                .foregroundStyle(.tint)
            }
            .chartYAxisLabel("min")
            .frame(height: 160)
            .padding(.vertical, Theme.Spacing.sm)
            .accessibilityLabel(Text("Minutes listened per day"))
        }
    }

    private func kinds(_ stats: ListeningStats) -> some View {
        Section("By Kind") {
            ForEach(stats.byKind.filter { $0.seconds > 0 }, id: \.mediaKind) { kind in
                LabeledContent {
                    Text(Self.duration(kind.seconds))
                } label: {
                    Label(Self.kindTitle(kind.mediaKind), systemImage: Self.kindIcon(kind.mediaKind))
                }
            }
            if !stats.byKind.contains(where: { $0.seconds > 0 }) {
                Text("Nothing yet in this period.").foregroundStyle(Theme.Colors.muted)
            }
        }
    }

    @ViewBuilder
    private func top(_ stats: ListeningStats) -> some View {
        let items = stats.topItems.prefix(10)
        if !items.isEmpty {
            Section("Most Played") {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    LabeledContent {
                        Text(Self.duration(item.seconds))
                    } label: {
                        Label {
                            Text(item.title ?? String(localized: "Deleted"))
                                .foregroundStyle(item.title == nil ? Theme.Colors.muted : Theme.Colors.foreground)
                                .lineLimit(2)
                        } icon: {
                            Image(systemName: Self.kindIcon(item.mediaKind))
                        }
                    }
                }
            }
        }
    }

    private func familySection(_ members: [MemberListening]) -> some View {
        Section {
            ForEach(members) { member in
                LabeledContent(member.name) {
                    if let seconds = member.totalSeconds {
                        Text(Self.duration(seconds))
                    } else {
                        Text("Private").foregroundStyle(Theme.Colors.muted)
                    }
                }
                .accessibilityIdentifier("listening.member")
            }
        } header: {
            Text("Family")
        } footer: {
            Text("As the family's admin you see the time of those who share it with you. Each member decides that in their own app.")
        }
    }

    private var sharing: some View {
        Section {
            Toggle("Share with the Family's Admin", isOn: Binding(
                get: { shared },
                set: { value in Task { await setShared(value) } }
            ))
            .disabled(isSavingShared)
            .accessibilityIdentifier("listening.share")
        } footer: {
            Text("Lets the admin see how long you listen, and to what kind. Off, your listening stays yours.")
        }
    }

    private func load() async {
        do {
            let stats = try await model.listeningStats(serverId: serverId, range: range)
            shared = stats.statsVisibility == "family_admin"
            family = try? await model.familyListening(serverId: serverId, range: range)
            state = .loaded(stats)
        } catch SourceError.unsupported {
            state = .failed(String(localized: "Sign in to this server again."))
        } catch {
            state = .failed((error as? SourceError)?.userMessage ?? error.localizedDescription)
        }
    }

    private func setShared(_ value: Bool) async {
        isSavingShared = true
        defer { isSavingShared = false }
        do {
            try await model.setStatsShared(serverId: serverId, value)
            shared = value
        } catch {
            model.actionError = (error as? SourceError)?.userMessage ?? error.localizedDescription
        }
    }

    static func duration(_ seconds: Int) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = seconds >= 3600 ? [.hours, .minutes] : [.minutes]
        return Duration.seconds(seconds).formatted(.units(allowed: units, width: .abbreviated))
    }

    static func date(_ day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: day)
    }

    static func kindTitle(_ kind: String) -> LocalizedStringKey {
        switch kind {
        case "music": "Music"
        case "podcast": "Podcasts"
        default: "Audiobooks"
        }
    }

    static func kindIcon(_ kind: String) -> String {
        switch kind {
        case "music": "music.note"
        case "podcast": "mic"
        default: "book.closed"
        }
    }
}
