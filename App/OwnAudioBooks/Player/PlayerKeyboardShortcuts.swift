import SwiftUI
import UIKit

/// Keys for a hardware keyboard, on a Mac or an iPad: Space plays or pauses, ⌘← and ⌘→ skip by
/// the listener's intervals. Hung on the root and on the full player, which is presented over
/// it. Off while a text field is being edited, so Space types a space and ⌘← moves the cursor.
struct PlayerKeyboardShortcuts: ViewModifier {
    @Environment(AppModel.self) private var model
    private let typing = TextEditingWatch.shared

    func body(content: Content) -> some View {
        content.background {
            let engine = model.engine
            VStack {
                Button("Play or Pause") { engine.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Skip Back") { engine.skipBackward() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Skip Forward") { engine.skipForward() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            .disabled(model.nowPlayingBook == nil || typing.isEditing)
            // Invisible but still in the hierarchy: a hidden button's shortcut does not fire.
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func playerKeyboardShortcuts() -> some View { modifier(PlayerKeyboardShortcuts()) }
}

/// Whether any text field or text view is being edited. SwiftUI has no app-wide focus to ask,
/// but its fields are UIKit's underneath (search fields and alert fields too), and those say
/// when editing begins and ends.
@MainActor @Observable
final class TextEditingWatch {
    static let shared = TextEditingWatch()

    var isEditing: Bool { editing > 0 }
    private var editing = 0
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        let changes: [(Notification.Name, Int)] = [
            (UITextField.textDidBeginEditingNotification, 1),
            (UITextView.textDidBeginEditingNotification, 1),
            (UITextField.textDidEndEditingNotification, -1),
            (UITextView.textDidEndEditingNotification, -1),
        ]
        for (name, step) in changes {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self.map { $0.editing = max(0, $0.editing + step) } }
            })
        }
    }
}
