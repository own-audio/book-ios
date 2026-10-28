import AVKit
import SwiftUI

/// The system's AirPlay and Bluetooth route picker. Copied from the music app (through the podcasts app); the colours follow
/// the player here, which is light or dark with the system, not always dark.
struct AirPlayRouteButton: UIViewRepresentable {
    @AppStorage(AccentChoice.storageKey) private var accent: AccentChoice = .app

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.tintColor = .label
        view.activeTintColor = UIColor(accent.color)
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.activeTintColor = UIColor(accent.color)
    }
}
