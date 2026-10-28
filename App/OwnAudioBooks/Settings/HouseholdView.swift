import BookLibrary
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The household on an own.audio server: who is in it, an invitation for someone new (admins),
/// and joining another household with a code.
struct HouseholdView: View {
    @Environment(AppModel.self) private var model
    @State private var state: LoadState<HouseholdInfo> = .loading
    @State private var invites: [HouseholdInvite] = []
    @State private var storage: HouseholdStorage?
    @State private var credit: HouseholdCredit?
    @State private var shownInvite: HouseholdInvite?
    @State private var isCreatingInvite = false
    @State private var isAskingCode = false
    @State private var code = ""
    @State private var isConfirmingJoin = false

    var body: some View {
        LoadStateView(state: state, retry: { Task { await load() } }) { household in
            List {
                Section {
                    header(household)
                }
                .listRowBackground(Color.clear)

                Section {
                    ForEach(household.members) { member in
                        MemberRow(member: member)
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text("What you add to the library is yours. Share a book from its menu; everyone in the family can then listen to it, each from their own position.")
                }

                if let storage {
                    Section {
                        StorageBar(storage: storage)
                            .listRowSeparator(.hidden)
                        StorageRow(title: "Audiobooks", bytes: storage.audiobooks, colour: StorageBar.audiobooks)
                        StorageRow(title: "Music", bytes: storage.music, colour: StorageBar.music)
                        StorageRow(title: "Podcasts", bytes: storage.podcasts, colour: StorageBar.podcasts)
                    } header: {
                        HStack {
                            Text("Storage")
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file))
                                .accessibilityIdentifier("family.storageTotal")
                        }
                    }
                }

                if let credit {
                    Section {
                        LabeledContent("Balance") {
                            Text(credit.balance, format: .currency(code: credit.currency))
                                .foregroundStyle(credit.isDepleted ? AnyShapeStyle(Theme.Colors.error) : AnyShapeStyle(.primary))
                                .accessibilityIdentifier("family.credit")
                        }
                        LabeledContent("A Month at Today's Storage") {
                            Text(credit.monthlyCost, format: .currency(code: credit.currency))
                        }
                        if let days = credit.daysLeft {
                            LabeledContent("Lasts About") {
                                Text("\(days) days")
                            }
                        }
                    } header: {
                        Text("Credit")
                    } footer: {
                        Text(credit.isDepleted
                             ? "The family's credit has run out."
                             : "Storage is paid from the family's prepaid credit, day by day.")
                    }
                }

                if household.isAdmin {
                    Section {
                        Button {
                            createInvite()
                        } label: {
                            HStack {
                                Label("Invite Someone", systemImage: "person.badge.plus")
                                if isCreatingInvite {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(isCreatingInvite || model.isOffline)
                        .accessibilityIdentifier("household.invite")
                        ForEach(invites) { invite in
                            Button {
                                shownInvite = invite
                            } label: {
                                LabeledContent {
                                    if let expires = invite.expiresAt {
                                        Text(expires, format: .dateTime.day().month())
                                    }
                                } label: {
                                    Text(invite.code).font(.body.monospaced())
                                }
                            }
                            .swipeActions {
                                Button("Withdraw", role: .destructive) { withdraw(invite) }
                            }
                        }
                    } header: {
                        Text("Invitations")
                    } footer: {
                        Text("An invitation is a code for one person. They sign in to this server and enter it, or open its link.")
                    }
                }

                Section {
                    Button {
                        code = ""
                        isAskingCode = true
                    } label: {
                        Label("Join Another Family…", systemImage: "person.2.badge.key")
                    }
                    .disabled(model.isOffline)
                } footer: {
                    Text("With a code from that family's admin. You then leave this one.")
                }
            }
        }
        .navigationTitle("Family")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .sheet(item: $shownInvite) { invite in
            InviteSheet(invite: invite)
        }
        .alert("Join Another Family", isPresented: $isAskingCode) {
            TextField("Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Join") { isConfirmingJoin = true }
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Enter the code from the invitation.")
        }
        .confirmationDialog("Leave this family and join the other one?", isPresented: $isConfirmingJoin, titleVisibility: .visible) {
            Button("Join") { join() }
        } message: {
            Text("What its members share appears instead of what this family shares.")
        }
    }

    private func header(_ household: HouseholdInfo) -> some View {
        VStack(spacing: Theme.Spacing.sm) {
            FamilyPicture(name: household.picture) {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.tint.opacity(0.12))
            }
            .frame(width: 104, height: 104)
            .clipShape(Circle())
            .accessibilityHidden(true)
            Text(household.name).font(.title2.bold())
            Text("\(household.members.count) members")
                .font(.subheadline)
                .foregroundStyle(Theme.Colors.muted)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        guard let household = model.household else { return }
        do {
            async let used = try? household.storage()
            async let paid = try? household.credit()
            let info = try await household.household()
            state = .loaded(info)
            invites = info.isAdmin ? ((try? await household.invites()) ?? []) : []
            storage = await used
            credit = await paid ?? nil
        } catch let error as SourceError {
            state = .failed(error.userMessage)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func createInvite() {
        guard let household = model.household else { return }
        isCreatingInvite = true
        model.perform {
            defer { isCreatingInvite = false }
            let invite = try await household.createInvite()
            invites.insert(invite, at: 0)
            shownInvite = invite
        }
    }

    private func withdraw(_ invite: HouseholdInvite) {
        guard let household = model.household else { return }
        model.perform {
            try await household.deleteInvite(id: invite.id)
            invites.removeAll { $0.id == invite.id }
        }
    }

    private func join() {
        guard let household = model.household, let serverId = model.activeServerId else { return }
        let code = code
        model.perform {
            state = .loaded(try await household.joinHousehold(code: code))
            // Another household's books: the library on the phone starts again.
            await model.resyncCatalogue(serverId)
        }
    }
}

extension AppModel {
    /// The active server's household — own.audio servers only.
    var household: (any HouseholdSource)? { activeSource as? any HouseholdSource }

    /// Whether the book is the listener's own on a server that shares with a household.
    func canShare(_ book: Book, serverId: UUID) -> Bool {
        guard let source = source(for: serverId) as? any HouseholdSource, source.capabilities.contains(.familySharing),
              let ownerId = book.ownerId
        else { return false }
        return ownerId == server(serverId)?.userId
    }

    func setShared(_ book: Book, serverId: UUID, _ shared: Bool) async throws {
        guard let source = source(for: serverId) as? any HouseholdSource else { throw SourceError.unsupported }
        try await source.setShared(bookId: book.id, shared)
    }
}

private struct MemberRow: View {
    let member: HouseholdMember

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            FamilyPicture(name: member.picture) { initials }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if member.isMe { Text("\(member.name) (you)") } else { Text(member.name) }
                if let role {
                    Text(role).font(.caption).foregroundStyle(Theme.Colors.muted)
                }
            }
        }
    }

    private var role: LocalizedStringKey? {
        if member.isPending { return "Invited" }
        return member.isAdmin ? "Admin" : nil
    }

    /// The family's colours, one per person, as in the own.audio logo.
    private static let colours: [Color] = [
        Color(red: 0.98, green: 0.73, blue: 0.02), Color(red: 0.16, green: 0.67, blue: 0.89),
        Color(red: 1.0, green: 0.23, blue: 0.19), Color(red: 1.0, green: 0.8, blue: 0.0),
        Color(red: 0.2, green: 0.78, blue: 0.35),
    ]

    private var initials: some View {
        let letters = member.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
        // From the id, so a member keeps their colour (`hashValue` changes every launch).
        let colour = Self.colours[member.id.unicodeScalars.reduce(0) { $0 + Int($1.value) } % Self.colours.count]
        return Text(letters.uppercased())
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(colour)
    }
}

/// An invitation to hand on: its code, a QR code of its link, and the share sheet.
private struct InviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let invite: HouseholdInvite

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.lg) {
                if let qr {
                    Image(uiImage: qr)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .padding()
                        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.miniPlayer))
                        .accessibilityLabel("QR code of the invitation")
                }
                Text(invite.code)
                    .font(.title.monospaced().bold())
                    .textSelection(.enabled)
                    .accessibilityIdentifier("household.inviteCode")
                Text("Scanned or typed in, it lets one person join your family.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.Colors.muted)
                    .multilineTextAlignment(.center)
                ShareLink(item: invite.joinURL?.absoluteString ?? invite.code) {
                    Label("Share Invitation", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding(Theme.Spacing.lg)
            .navigationTitle("Invitation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var qr: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data((invite.joinURL?.absoluteString ?? invite.code).utf8)
        guard let image = filter.outputImage,
              let cg = CIContext().createCGImage(image, from: image.extent)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// What the family keeps, as one bar in three colours.
private struct StorageBar: View {
    static let audiobooks = Theme.Colors.accent
    static let music = Color(red: 0.43, green: 0.27, blue: 1.0)
    static let podcasts = Color(red: 0.16, green: 0.67, blue: 0.89)

    let storage: HouseholdStorage

    var body: some View {
        GeometryReader { geometry in
            let total = max(Double(storage.audiobooks + storage.music + storage.podcasts), 1)
            HStack(spacing: 2) {
                ForEach(Array([(storage.audiobooks, Self.audiobooks), (storage.music, Self.music), (storage.podcasts, Self.podcasts)].enumerated()), id: \.offset) { _, part in
                    if part.0 > 0 {
                        part.1.frame(width: max(geometry.size.width * Double(part.0) / total - 2, 3))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 12)
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityHidden(true)
    }
}

private struct StorageRow: View {
    let title: LocalizedStringKey
    let bytes: Int64
    let colour: Color

    var body: some View {
        LabeledContent {
            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Circle().fill(colour).frame(width: 10, height: 10)
                Text(title)
            }
        }
    }
}

/// A family or member picture, fetched with the account's sign-in (the server doesn't sign
/// these links), and kept for the app's lifetime; `placeholder` until then, or without one.
private struct FamilyPicture<Placeholder: View>: View {
    @Environment(AppModel.self) private var model
    let name: String?
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder()
            }
        }
        .task(id: name) {
            guard let name else { image = nil; return }
            if let known = FamilyPictures.loaded[name] { image = known; return }
            guard let data = try? await model.household?.picture(name), let picture = UIImage(data: data) else { return }
            FamilyPictures.loaded[name] = picture
            image = picture
        }
    }
}

/// Pictures already fetched, by name, for as long as the app runs.
@MainActor private enum FamilyPictures {
    static var loaded: [String: UIImage] = [:]
}
