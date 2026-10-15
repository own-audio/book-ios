import BookLibrary
import SwiftUI

/// The devices signed in to an own.audio account, with this one marked; any can be signed
/// out, or all of them at once.
struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let serverId: UUID
    @State private var state: LoadState<[DeviceSession]> = .loading
    @State private var isConfirmingAll = false

    var body: some View {
        List {
            Section {
                LoadStateView(state: state, retry: load) { sessions in
                    ForEach(sessions) { session in
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: Self.symbol(session.kind))
                                .foregroundStyle(Theme.Colors.accent)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Theme.Spacing.xs) {
                                    Text(session.name ?? session.kind.capitalized)
                                    if session.isThisDevice {
                                        Text("This device")
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.Colors.accent.opacity(0.15), in: Capsule())
                                            .foregroundStyle(Theme.Colors.accent)
                                    }
                                }
                                Group {
                                    if let used = session.lastUsedAt {
                                        Text("Last used \(used, style: .relative) ago")
                                    } else {
                                        Text("Signed in \(session.signedInAt, style: .date)")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(Theme.Colors.muted)
                            }
                        }
                        .swipeActions {
                            if !session.isThisDevice {
                                Button(role: .destructive) {
                                    signOut(session)
                                } label: {
                                    Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            }
                        }
                        .accessibilityIdentifier("devices.\(session.id)")
                    }
                }
            } footer: {
                Text("Swipe a device to sign it out. Signing out everywhere ends every session, this iPhone's too, and asks for a fresh sign-in.")
            }
            Section {
                Button("Sign Out Everywhere", role: .destructive) { isConfirmingAll = true }
                    .accessibilityIdentifier("devices.signOutEverywhere")
            }
        }
        .navigationTitle("Devices")
        .task(id: serverId) { load() }
        .confirmationDialog("Sign Out Everywhere?", isPresented: $isConfirmingAll, titleVisibility: .visible) {
            Button("Sign Out Everywhere", role: .destructive) {
                model.perform {
                    try await model.signOutEverywhere(serverId: serverId)
                    dismiss()
                }
            }
        }
    }

    private static func symbol(_ kind: String) -> String {
        switch kind {
        case "ios": "iphone"
        case "macos": "laptopcomputer"
        case "web": "safari"
        case "android": "smartphone"
        case "tvos": "appletv"
        case "windows": "pc"
        default: "desktopcomputer"
        }
    }

    private func load() {
        Task {
            do {
                // This device first, then the most recently used.
                let sessions = try await model.sessions(serverId: serverId).sorted {
                    if $0.isThisDevice != $1.isThisDevice { return $0.isThisDevice }
                    return ($0.lastUsedAt ?? $0.signedInAt) > ($1.lastUsedAt ?? $1.signedInAt)
                }
                state = .loaded(sessions)
            } catch let error as SourceError {
                state = .failed(error.userMessage)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func signOut(_ session: DeviceSession) {
        if case .loaded(let sessions) = state { state = .loaded(sessions.filter { $0.id != session.id }) }
        model.perform { try await model.revokeSession(serverId: serverId, id: session.id) }
    }
}
