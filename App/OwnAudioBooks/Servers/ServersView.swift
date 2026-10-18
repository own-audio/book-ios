import BookLibrary
import SwiftUI

/// Every configured server: pick the one to browse, check, rename, sign in again or remove.
struct ServersView: View {
    @Environment(AppModel.self) private var model
    @State private var isAdding = false
    @State private var renaming: ServerRecord?
    @State private var newName = ""
    @State private var statuses: [UUID: ConnectionStatus] = [:]
    @State private var checking: Set<UUID> = []
    @State private var signingIn: ServerRecord?
    @State private var pickingLibrary: ServerRecord?

    var body: some View {
        List {
            Section {
                ForEach(model.serversInOrder) { server in row(server) }
            } footer: {
                Text("The library shows the selected server. A book keeps playing when you switch.")
            }
            Section {
                Button { isAdding = true } label: { Label("Add Server", systemImage: "plus") }
                    .accessibilityIdentifier("servers.add")
            }
        }
        .navigationTitle("Servers")
        .sheet(isPresented: $isAdding) { NavigationStack { AddServerView() } }
        .sheet(item: $signingIn) { server in SignInAgainView(server: server) }
        .sheet(item: $pickingLibrary) { server in LibraryPickerView(server: server) }
        .alert("Rename Server", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                guard let server = renaming else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                renaming = nil
                guard !name.isEmpty else { return }
                model.perform { try await model.renameServer(id: server.id, to: name) }
            }
        }
    }

    private func row(_ server: ServerRecord) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            selectButton(server)
            NavigationLink { ServerDetailView(server: server) } label: { Image(systemName: "info.circle").font(.title3) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Details")
                .accessibilityIdentifier("servers.info.\(server.displayName)")
        }
        .swipeActions {
            Button(role: .destructive) {
                model.perform { try await model.removeServer(id: server.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .contextMenu {
            Button { check(server) } label: { Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right") }
            Button { signingIn = server } label: { Label("Sign In Again…", systemImage: "key") }
            if server.kind == .audiobookshelf {
                Button { pickingLibrary = server } label: { Label("Library…", systemImage: "books.vertical") }
            }
            Button { newName = server.displayName; renaming = server } label: { Label("Rename…", systemImage: "pencil") }
            Button(role: .destructive) {
                model.perform { try await model.removeServer(id: server.id) }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func selectButton(_ server: ServerRecord) -> some View {
        Button {
            Haptics.selection()
            model.selectServer(id: server.id)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: server.kind == .ownAudio ? "person.2.fill" : "books.vertical.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName).foregroundStyle(.primary)
                    Text(server.kind == .ownAudio ? "own.audio" : "Audiobookshelf")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("servers.kind.\(server.displayName)")
                    Text("\(server.auth.username) · \((model.activeAddresses[server.id] ?? server.host).host() ?? "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    statusText(server)
                }
                Spacer()
                if server.id == model.activeServerId {
                    Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityLabel("Selected")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("servers.row.\(server.displayName)")
    }

    @ViewBuilder
    private func statusText(_ server: ServerRecord) -> some View {
        if model.signInRefused.contains(server.id) || !server.auth.isSignedIn {
            Button("Sign-in refused · Sign in again") { signingIn = server }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .buttonStyle(.plain)
                .accessibilityIdentifier("servers.refused.\(server.displayName)")
        } else if checking.contains(server.id) {
            Text("Checking…").font(.caption).foregroundStyle(.secondary)
        } else if let status = statuses[server.id] {
            Text(status == .ok ? "Connected" : status == .rejected ? "Sign-in refused" : "Unreachable")
                .font(.caption)
                .foregroundStyle(status == .ok ? .green : .red)
                .accessibilityIdentifier("servers.status.\(server.displayName)")
        } else if case .unreachable = model.connectionStates[server.id] {
            Text("Unreachable").font(.caption).foregroundStyle(.red)
        }
    }

    private func check(_ server: ServerRecord) {
        checking.insert(server.id)
        Task {
            statuses[server.id] = await model.checkConnection(id: server.id)
            checking.remove(server.id)
        }
    }
}

/// The same account, signed in again after the server refused a refresh.
struct SignInAgainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server.displayName)
                    LabeledContent("Account", value: server.auth.username)
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("signInAgain.password")
                }
                if let errorMessage {
                    Section { Label(errorMessage, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    Button {
                        submit()
                    } label: {
                        HStack { Spacer(); if isWorking { ProgressView() } else { Text("Sign In").bold() }; Spacer() }
                    }
                    .disabled(password.isEmpty || isWorking)
                    .accessibilityIdentifier("signInAgain.submit")
                }
                if server.kind == .ownAudio {
                    Section {
                        ProviderButtons(address: server.host.absoluteString, name: server.displayName, isWorking: $isWorking, replacing: server.id) { dismiss() }
                            .listRowBackground(Color.clear)
                    }
                }
            }
            .navigationTitle("Sign In Again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(item: model.pendingTwoFactorBinding) { _ in TwoFactorView { dismiss() } }
        }
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await model.signInAgain(serverId: server.id, username: server.auth.username, password: password)
                dismiss()
            } catch where error.isTwoFactorNeeded {
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }
}

/// Which of an Audiobookshelf account's book libraries the app shows.
struct LibraryPickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    @State private var libraries: [(id: String, name: String)] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            List {
                if isLoading {
                    ProgressView()
                } else if libraries.isEmpty {
                    Text("No book library could be listed.").foregroundStyle(.secondary)
                } else {
                    ForEach(libraries, id: \.id) { library in
                        Button {
                            model.perform { try await model.setLibrary(serverId: server.id, libraryId: library.id) }
                            dismiss()
                        } label: {
                            HStack {
                                Text(library.name).foregroundStyle(.primary)
                                Spacer()
                                if library.id == server.libraryId { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityIdentifier("libraryPicker.\(library.name)")
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                libraries = await model.bookLibraries(serverId: server.id)
                isLoading = false
            }
        }
    }
}

/// One server: its account and address, a connection check, and for own.audio the library on
/// this iPhone with when it was last updated.
struct ServerDetailView: View {
    @Environment(AppModel.self) private var model
    let server: ServerRecord
    @State private var status: ConnectionStatus?
    @State private var isChecking = false
    @State private var isSigningIn = false
    @State private var libraries: [(id: String, name: String)] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Account", value: server.auth.username)
                LabeledContent("Address", value: (model.activeAddresses[server.id] ?? server.host).absoluteString)
                LabeledContent("Server", value: server.kind == .ownAudio ? "own.audio" : "Audiobookshelf")
            }
            Section {
                Button { check() } label: {
                    HStack {
                        Label("Check Connection", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        if isChecking {
                            ProgressView()
                        } else if let status {
                            Text(status == .ok ? "Connected" : status == .rejected ? "Sign-in refused" : "Unreachable")
                                .foregroundStyle(status == .ok ? .green : .red)
                                .accessibilityIdentifier("serverDetail.checkResult")
                        }
                    }
                }
                .disabled(isChecking)
                .accessibilityIdentifier("serverDetail.check")
                Button { isSigningIn = true } label: { Label("Sign In Again…", systemImage: "key") }
            }
            if server.kind == .audiobookshelf {
                Section {
                    if libraries.isEmpty {
                        Text(model.isOffline ? "Offline" : "Loading…").foregroundStyle(Theme.Colors.muted)
                    }
                    ForEach(libraries, id: \.id) { library in
                        Button {
                            model.perform { try await model.setLibrary(serverId: server.id, libraryId: library.id) }
                        } label: {
                            HStack {
                                Text(library.name).foregroundStyle(Theme.Colors.foreground)
                                Spacer()
                                if library.id == model.server(server.id)?.libraryId { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                        .accessibilityIdentifier("serverDetail.library.\(library.name)")
                    }
                } header: {
                    Text("Library")
                } footer: {
                    Text("The book library this app shows from the server. With several, each is also in the switch on Home.")
                }
            }
            if server.kind == .ownAudio {
                Section {
                    catalogueRow
                    Button("Update Now") { Task { await model.updateCatalogue(server.id) } }
                        .disabled(model.catalogueSyncing.contains(server.id) || model.isOffline)
                        .accessibilityIdentifier("serverDetail.syncCatalogue")
                } header: {
                    Text("Library on This iPhone")
                } footer: {
                    Text("A list of everything on the server, without the audio, so the library can be browsed offline. Updated at launch and when the app comes to the foreground.")
                }
            }
        }
        .navigationTitle(server.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isSigningIn) { SignInAgainView(server: server) }
        .task {
            if server.kind == .audiobookshelf { libraries = await model.bookLibraries(serverId: server.id) }
        }
    }

    @ViewBuilder
    private var catalogueRow: some View {
        if model.catalogueSyncing.contains(server.id) {
            HStack { Text("Updating…"); Spacer(); ProgressView() }
        } else if let summary = model.catalogueSummary(serverId: server.id) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Books: \(summary.books) · Authors: \(summary.authors)")
                if let at = summary.syncedAt {
                    Text("Updated \(at.formatted(.relative(presentation: .named)))").font(.footnote).foregroundStyle(Theme.Colors.muted)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("serverDetail.catalogue")
        } else {
            Text("Not synced yet").foregroundStyle(Theme.Colors.muted)
        }
    }

    private func check() {
        isChecking = true
        Task {
            status = await model.checkConnection(id: server.id)
            isChecking = false
        }
    }
}
