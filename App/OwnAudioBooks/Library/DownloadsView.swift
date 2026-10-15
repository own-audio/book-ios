import BookLibrary
import SwiftUI

/// What is on this iPhone: every downloaded book with its size, to open, play or remove.
struct DownloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var isConfirmingRemoveAll = false

    private var books: [DownloadManager.DownloadedBook] {
        model.downloads.books.values.sorted { ($0.finishedAt ?? $0.startedAt) > ($1.finishedAt ?? $1.startedAt) }
    }

    var body: some View {
        List {
            if books.isEmpty {
                ContentUnavailableView("Nothing Downloaded", systemImage: "arrow.down.circle", description: Text("Download a book from its page to listen with no network."))
            }
            ForEach(books) { entry in
                NavigationLink(value: LibraryRoute.book(entry.book, serverId: entry.serverId)) {
                    HStack(spacing: Theme.Spacing.md) {
                        CoverView(book: entry.book, serverId: entry.serverId, pointSize: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.book.title).font(.body.weight(.semibold)).foregroundStyle(Theme.Colors.foreground).lineLimit(2)
                            Text(entry.book.authorLine).font(.subheadline).foregroundStyle(Theme.Colors.muted).lineLimit(1)
                            Text(status(entry)).font(.caption).foregroundStyle(Theme.Colors.muted)
                        }
                    }
                }
                .accessibilityIdentifier("downloads.\(entry.book.id)")
                .swipeActions {
                    Button(role: .destructive) { model.downloads.remove(entry.id) } label: { Label("Remove", systemImage: "trash") }
                }
            }
            if !books.isEmpty {
                Section {
                    Button("Remove All Downloads", role: .destructive) { isConfirmingRemoveAll = true }
                        .accessibilityIdentifier("downloads.removeAll")
                } footer: {
                    Text("\(ByteCountFormatter.string(fromByteCount: model.downloads.totalBytes, countStyle: .file)) on this iPhone.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Downloads")
        .confirmationDialog("Remove All Downloads?", isPresented: $isConfirmingRemoveAll, titleVisibility: .visible) {
            Button("Remove All Downloads", role: .destructive) { model.downloads.removeAll() }
        }
    }

    private func status(_ entry: DownloadManager.DownloadedBook) -> String {
        switch model.downloads.state(of: entry.id) {
        case .downloading(let fraction): String(localized: "Downloading… \(Int(fraction * 100))%")
        case .failed(let message): message
        case .downloaded, nil: ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file)
        }
    }
}

/// The download button beside Play: an arrow, a ring while downloading, a check when done.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let book: Book
    let serverId: UUID
    @State private var isConfirmingRemove = false

    var body: some View {
        let state = model.downloadState(book, serverId: serverId)
        Button {
            switch state {
            case .downloaded: isConfirmingRemove = true
            case .downloading: break
            case .failed: model.removeDownload(book, serverId: serverId); Task { await model.download(book, serverId: serverId) }
            case nil: Task { await model.download(book, serverId: serverId) }
            }
        } label: {
            Group {
                switch state {
                case .downloaded:
                    Image(systemName: "checkmark.circle.fill").font(.title2)
                case .downloading(let fraction):
                    ZStack {
                        Circle().stroke(Theme.Colors.accent.opacity(0.25), lineWidth: 3)
                        Circle().trim(from: 0, to: max(fraction, 0.02)).stroke(Theme.Colors.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                    }
                    .frame(width: 22, height: 22)
                case .failed:
                    Image(systemName: "exclamationmark.arrow.circlepath").font(.title2)
                case nil:
                    Image(systemName: "arrow.down.circle").font(.title2)
                }
            }
            .frame(minWidth: Theme.minTarget, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .tint(Theme.Colors.accent)
        .disabled(model.isOffline && state == nil)
        .accessibilityIdentifier("detail.download")
        .accessibilityLabel(label(state))
        .confirmationDialog("Remove Download?", isPresented: $isConfirmingRemove, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { model.removeDownload(book, serverId: serverId) }
        }
    }

    private func label(_ state: DownloadManager.State?) -> String {
        switch state {
        case .downloaded: String(localized: "Downloaded")
        case .downloading(let fraction): String(localized: "Downloading \(Int(fraction * 100))%")
        case .failed: String(localized: "Download failed, try again")
        case nil: String(localized: "Download")
        }
    }
}

/// The badge in a card's corner: a ring while downloading, a check when the book is on the phone.
struct DownloadBadge: View {
    let state: DownloadManager.State?

    var body: some View {
        switch state {
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundStyle(.white)
                .padding(5)
                .background(Theme.Colors.accent, in: Circle())
                .accessibilityLabel("Downloaded")
        case .downloading(let fraction):
            ZStack {
                Circle().fill(Theme.Colors.accent)
                Circle().trim(from: 0, to: max(fraction, 0.02)).stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90)).padding(4)
            }
            .frame(width: 22, height: 22)
            .accessibilityLabel("Downloading")
        default:
            EmptyView()
        }
    }
}

/// A line above the mini player while the app is offline, so a shorter library isn't a mystery.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isOffline {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "wifi.slash")
                Text(model.isOfflineByChoice ? "Offline Mode · downloaded books only" : "No network · downloaded books only")
                Spacer(minLength: 0)
                if model.isOfflineByChoice {
                    Button("Turn Off") {
                        model.setOfflineMode(false)
                        if model.settings.mobileData == .downloadedOnly { model.settings.mobileData = .saver }
                    }
                    .font(.footnote.weight(.semibold))
                    .accessibilityIdentifier("offline.turnOff")
                }
            }
            .font(.footnote)
            .foregroundStyle(Theme.Colors.muted)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.sm)
            .background(.bar)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("offline.banner")
        }
    }
}
