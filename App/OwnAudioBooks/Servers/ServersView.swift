import BookLibrary
import SwiftUI

/// The servers, listed in Settings as in the podcasts app: a tap opens the server's page
/// (use it, check it, sign in again, rename it, remove it); a swipe removes one, after asking.
/// The selected server — the one the library shows — has a checkmark.
struct ServersSection: View {
    @Environment(AppModel.self) private var model
    /// Owned by Settings, which shows the sheet: hung on this section, it closed at once.
    @Binding var isAdding: Bool
    /// Owned by Settings, where the question is asked: a dialog on a section of a form didn't
    /// show on iOS 26.5.
    @Binding var removing: ServerRecord?

    var body: some View {
        Section {
            ForEach(model.serversInOrder) { server in
                NavigationLink {
                    ServerDetailView(server: server)
                } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        ServerIcon(brand: ServerBrand(server), image: model.serverIcons[server.id], size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(server.displayName).foregroundStyle(Theme.Colors.foreground)
                            Text("\(server.kind == .ownAudio ? "own.audio" : "Audiobookshelf") · \(server.auth.username)")
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.muted)
                                .lineLimit(1)
                                .accessibilityIdentifier("servers.kind.\(server.displayName)")
                            if model.signInRefused.contains(server.id) || !server.auth.isSignedIn {
                                Text("Sign-in refused · Sign in again")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.red)
                                    .accessibilityIdentifier("servers.refused.\(server.displayName)")
                            }
                        }
                        Spacer()
                        if server.id == model.activeServerId {
                            Image(systemName: "checkmark").foregroundStyle(Theme.Colors.muted).accessibilityLabel("Selected")
                        }
                    }
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { removing = server }
                }
                .accessibilityIdentifier("servers.row.\(server.displayName)")
            }
            Button { isAdding = true } label: { Label("Add a Server", systemImage: "plus") }
                .accessibilityIdentifier("servers.add")
        } header: {
            Text("Servers")
        } footer: {
            Text("The library shows the selected server. A book keeps playing when you switch.")
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
    @Environment(\.dismiss) private var dismiss
    let server: ServerRecord
    @State private var isRenaming = false
    @State private var newName = ""
    @State private var confirmRemove = false
    @State private var status: ConnectionStatus?
    @State private var isChecking = false
    @State private var isSigningIn = false
    @State private var libraries: [(id: String, name: String)] = []
    @State private var isAddingAddress = false
    @State private var newAddress = ""
    @State private var addressError: String?
    @State private var confirmDeleteAccount = false

    /// The record as it is now: addresses change while the page is open.
    private var current: ServerRecord { model.server(server.id) ?? server }

    private var fixedAddress: URL? {
        if case .fixed(let url) = current.connection { url } else { nil }
    }

    var body: some View {
        List {
            // The library shows one server at a time; this one, from here.
            if server.id != model.activeServerId {
                Section {
                    Button {
                        Haptics.selection()
                        model.selectServer(id: server.id)
                    } label: {
                        Label("Use This Server", systemImage: "checkmark.circle")
                    }
                    .accessibilityIdentifier("serverDetail.use")
                } footer: {
                    Text("The library shows the selected server.")
                }
            }
            Section {
                Button { check() } label: {
                    HStack {
                        Text("Check Now")
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
            }
            Section {
                Button("Sign In Again") { isSigningIn = true }
                    .accessibilityIdentifier("serverDetail.signInAgain")
                // App Store guideline 5.1.1(v): an account the app can create (own.audio's Apple
                // and Google sign-in can) must be deletable in the app. Audiobookshelf accounts
                // are made by the server's admin, never here.
                if server.kind == .ownAudio, case .ownAudio(_, .some) = current.auth {
                    Button("Delete Account…", role: .destructive) { confirmDeleteAccount = true }
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("serverDetail.deleteAccount")
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Signed in as \(server.auth.username). Downloads and the library on this iPhone stay as they are.")
            }
            // The account's family and signed-in devices, on its server's page as in the
            // podcasts app.
            if server.kind == .ownAudio {
                Section {
                    if server.id == model.activeServerId, model.household != nil {
                        NavigationLink { HouseholdView() } label: { Label("Family", systemImage: "person.3") }
                            .accessibilityIdentifier("serverDetail.family")
                    }
                    NavigationLink { DevicesView(serverId: server.id) } label: { Label("Devices", systemImage: "iphone.gen3") }
                        .accessibilityIdentifier("serverDetail.devices")
                    NavigationLink { ListeningView(serverId: server.id) } label: { Label("Listening", systemImage: "chart.bar") }
                        .accessibilityIdentifier("serverDetail.listening")
                }
            }
            Section {
                LabeledContent("Server") {
                    HStack(spacing: Theme.Spacing.sm) {
                        ServerIcon(brand: ServerBrand(server), image: model.serverIcons[server.id], size: 22)
                        Text(server.kind == .ownAudio ? "own.audio" : "Audiobookshelf")
                    }
                }
                LabeledContent("Address", value: (model.activeAddresses[server.id] ?? server.host).absoluteString)
                // Renamed here, as in the podcasts and music apps.
                Button {
                    newName = current.displayName
                    isRenaming = true
                } label: {
                    LabeledContent("Name", value: current.displayName)
                }
                .foregroundStyle(Theme.Colors.foreground)
                .accessibilityIdentifier("serverDetail.name")
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
            Section("Connection") {
                Picker("Use", selection: Binding(
                    get: { fixedAddress },
                    set: { url in Task { await model.setFixedAddress(url, for: server.id) } }
                )) {
                    Text("Automatic").tag(URL?.none)
                    ForEach(current.candidateAddresses) { address in
                        Text(address.url.absoluteString).tag(URL?.some(address.url))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("serverDetail.mode")
            }
            Section {
                ForEach(current.candidateAddresses) { address in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address.url.absoluteString).lineLimit(1)
                        Text(origin(address)).font(.caption).foregroundStyle(Theme.Colors.muted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("serverDetail.address.\(address.url.absoluteString)")
                    .swipeActions {
                        if address.origin != .added {
                            Button(role: .destructive) {
                                Task { await model.removeAddress(address.url, from: server.id) }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                Button {
                    newAddress = ""
                    addressError = nil
                    isAddingAddress = true
                } label: {
                    Label("Add Address", systemImage: "plus")
                }
                .accessibilityIdentifier("serverDetail.addAddress")
                if let addressError { Text(addressError).font(.footnote).foregroundStyle(Theme.Colors.error) }
            } header: {
                Text("Addresses")
            } footer: {
                Text(server.kind == .ownAudio
                     ? "The server tells the app its other addresses. Add one it doesn't know, such as a VPN like Tailscale; on each network the app uses the fastest that answers as this server."
                     : "Add the server's address on your home network, a VPN such as Tailscale, or a second public name. On each network the app uses the fastest one that answers.")
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

            Section {
                Button("Remove Server", role: .destructive) { confirmRemove = true }
                    .accessibilityIdentifier("serverDetail.remove")
            }
        }
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                model.perform { try await model.renameServer(id: server.id, to: name) }
            }
        }
        .confirmationDialog("Remove \(current.displayName)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                let id = server.id
                dismiss()
                model.perform { try await model.removeServer(id: id) }
            }
        } message: {
            Text("Its downloads leave this iPhone. Nothing changes on the server.")
        }
        .confirmationDialog("Delete Your Account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                let id = server.id
                dismiss()
                model.perform { try await model.deleteAccount(serverId: id) }
            }
        } message: {
            Text("Your account on \(server.host.host() ?? server.displayName) is deleted for good, with everything you added to it: music, audiobooks, podcasts, playlists and your listening history. What others in your family added stays with them.")
        }
        .alert("Add Address", isPresented: $isAddingAddress) {
            TextField("http://192.168.1.20:13378", text: $newAddress)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("serverDetail.newAddress")
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let text = newAddress
                Task {
                    do { try await model.addAddress(text, to: server.id) } catch { addressError = error.localizedDescription }
                }
            }
        } message: {
            Text("Another address this server answers at.")
        }
        .navigationTitle(current.displayName)
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

    private func origin(_ address: ServerAddress) -> String {
        switch address.origin {
        case .added: String(localized: "Added with")
        case .server: String(localized: "From the server")
        case .user: String(localized: "Added by you")
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
