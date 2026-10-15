import SwiftUI

/// The first screen until B4 brings the real app: enough to launch, to be found by the UI
/// tests, and to prove the project builds on every commit.
struct RootView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "books.vertical")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("own.audio Books")
                .font(.title2.weight(.semibold))
            Text("In development")
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("root.placeholder")
    }
}

#Preview {
    RootView()
}
