import OSLog
import SwiftUI

/// What the app wrote to its log since it started — failed requests, playback trouble, sync —
/// to read, and to share as a text file with a bug report. Read on the phone from the system's
/// log store; nothing is sent anywhere unless the listener shares it. Addresses are logged
/// without their query, so no token is in it.
struct LogsView: View {
    @State private var lines: [Line]?
    @State private var failure: String?

    struct Line: Identifiable {
        let id: Int
        let date: Date
        let level: String
        let category: String
        let message: String

        var text: String { "\(date.formatted(.iso8601)) \(level) [\(category)] \(message)" }
    }

    var body: some View {
        List {
            if let lines {
                if lines.isEmpty {
                    ContentUnavailableView("Nothing Logged Yet", systemImage: "doc.text", description: Text("The app writes here when something goes wrong."))
                }
                ForEach(lines.reversed()) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(line.date.formatted(date: .omitted, time: .standard)) · \(line.category)")
                            .font(.caption2)
                            .foregroundStyle(line.level == "error" || line.level == "fault" ? Theme.Colors.error : Theme.Colors.muted)
                        Text(line.message).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            } else if let failure {
                Text(failure).foregroundStyle(Theme.Colors.muted)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Logs")
        .accessibilityIdentifier("logs.list")
        .toolbar {
            if let lines, !lines.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: export(lines), preview: SharePreview("own.book log")) {
                        Label("Share Log", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("logs.share")
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do {
            lines = try await Task.detached(priority: .userInitiated) { try Self.read() }.value
        } catch {
            failure = error.localizedDescription
        }
    }

    /// This run's entries from the app's own subsystems.
    private nonisolated static func read() throws -> [Line] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let start = store.position(timeIntervalSinceLatestBoot: 0)
        let predicate = NSPredicate(format: "subsystem BEGINSWITH %@", "audio.own.")
        var out: [Line] = []
        for case let entry as OSLogEntryLog in try store.getEntries(at: start, matching: predicate) {
            let level = switch entry.level {
            case .error: "error"
            case .fault: "fault"
            case .debug: "debug"
            case .info: "info"
            default: "notice"
            }
            out.append(Line(id: out.count, date: entry.date, level: level, category: entry.category, message: entry.composedMessage))
        }
        return Array(out.suffix(2000))
    }

    /// A text file to share: the app's version and the iOS version first.
    private func export(_ lines: [Line]) -> URL {
        let header = "own.book \(AppModel.appVersion), iOS \(UIDevice.current.systemVersion)\n\n"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("own-book-log.txt")
        try? (header + lines.map(\.text).joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
