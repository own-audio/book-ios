# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- The implementation plan, README, licence and working rules.
- The project (`project.yml`, iOS 18, Swift 6), an app that launches to a placeholder, and a
  launch UI test (B0).
- `ServerSupport`, `OwnAudioKit` and `PlayerCore`, copied from own.audio Music without their
  music-only parts; `scripts/` for tests against real servers, TestFlight and the App Store.
- `AudiobookshelfKit`: a client for Audiobookshelf 2.x — sign-in with rotating tokens (2.26+)
  or the older single token, libraries, items, series, authors, narrators, collections, the
  home shelves, search, progress, bookmarks, play sessions and local sessions, media and cover
  URLs, and a repair for mis-encoded titles (B1).
- `BookLibrary`: one set of models in book time, the `BookSource` interface with capabilities,
  an adapter for Audiobookshelf and one for own.audio (the library on the phone from the change
  feed), the Keychain server store, address scopes and racing, and the sign-in flows for both
  kinds of server; `OwnAudioKit` learned books, progress, bookmarks and per-file playback (B2).
- `SpokenEngine`: an AVPlayer over a book's files as one timeline — speed with pitch
  correction, chapters (the server's, or read from the file), skips, smart rewind, the sleep
  timer's end-of-chapter mode, lock-screen skip buttons, positions reported with the time
  listened, and a fresh link fetched when one fails (B3).
- The app: onboarding and Add Server for both kinds of server (with two-factor and the demo),
  Servers, Home shelves, Library with sort, filters, series, authors, narrators and
  collections, book detail with chapters, files and bookmarks, Search, the player with
  speed, skips, chapters, sleep timer and bookmarks, the mini player, Settings; positions
  saved on the phone first and sent to the server; UI tests against real servers (B4).
- The app icon: the own.audio family ring with a closed book in brown, from `Design/`.
- The look of own.audio's audiobook app: the brown accent, its tokens and radii, cards with
  badges and progress, a greeting on Home, the detail's capsule Play button filled with the
  progress, the player's book bar and chapter slider with labelled tools, the mini player on
  material, and the welcome screen over the own.audio hero with the mark and wordmark (B4b).
- The App Store listing in English and Czech (`AppStore/`), the review notes, `PRIVACY.md`,
  and the first TestFlight build (8).

- Czech, complete, beside English: the String Catalog with plural forms, the Info.plist
  strings, and a UI test of the Czech screens (B4c).

### Fixed

- The app icon set's manifest named no files, so no icon was compiled into the archive.
