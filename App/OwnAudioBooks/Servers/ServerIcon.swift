import BookLibrary
import SwiftUI
import UIKit

/// Which picture marks a server. own.audio's mark ships with the app. Audiobookshelf shows the
/// icon it serves itself, loaded from the listener's own server at run time (as a browser shows a
/// site's icon): its artwork is GPL-licensed and the app carries none of it. A symbol stands in
/// until it has loaded. Copied from the podcasts app.
enum ServerBrand {
    case ownAudio, audiobookshelf

    init(_ record: ServerRecord) {
        self = record.kind == .ownAudio ? .ownAudio : .audiobookshelf
    }

    var assetName: String? { self == .ownAudio ? "ServerLogo" : nil }
    var symbol: String { self == .ownAudio ? "person.3" : "books.vertical" }
}

/// A server's picture in a list, on a rounded tile.
struct ServerIcon: View {
    let brand: ServerBrand
    /// The server's own icon, when it has loaded.
    var image: UIImage?
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let name = brand.assetName {
                Image(name).resizable().scaledToFit()
            } else {
                ZStack {
                    Theme.Colors.backgroundAlt
                    Image(systemName: brand.symbol)
                        .font(.system(size: size * 0.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}
