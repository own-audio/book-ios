# own.audio Books

A native iPhone and iPad audiobook player for your own server: **own.audio and
Audiobookshelf**, side by side in one app. Swift and SwiftUI, no web views, no third-party
dependencies — a few megabytes.

In development; the plan is in [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md).

- Speed with pitch correction, chapters, skip buttons, smart rewind, sleep timer to the end of
  the chapter
- One position per book that follows you between devices; nothing is lost offline
- Chapters read from the file itself when the server has none
- Downloads and an offline mode: with no network it shows and plays what is on the phone
- Bookmarks, series, authors, narrators, collections — whatever the server offers
- Several servers at once; iPad; CarPlay
- With own.audio: a family library, importing books from the phone, a library on the phone
  that follows the server's changes
- English and Czech

Made by [own.audio](https://www.own.audio). Free, no account needed, no tracking.

## Build

Developed with Xcode 27 and [XcodeGen](https://github.com/yonaskolb/XcodeGen); runs on iOS 18
and later.

```bash
brew install xcodegen
xcodegen generate
open OwnAudioBooks.xcodeproj
```

## Layout

- `App/OwnAudioBooks/` — the app
- `Packages/AudiobookshelfKit/` — Audiobookshelf client
- `Packages/OwnAudioKit/` — own.audio client (`/api/v2`)
- `Packages/BookLibrary/` — one library model over both servers
- `Packages/PlayerEngine/` — the spoken-audio engine

## Privacy

The app talks only to the servers you add. See [PRIVACY.md](PRIVACY.md) once it exists, before
the first release.

## License

[MPL-2.0](LICENSE).
