# CLAUDE.md — book-ios

**own.audio Books**: one open-source (MPL-2.0) native iOS audiobook player for own.audio and
Audiobookshelf servers, published by own.audio. The repository is public — write everything
for strangers to read.

- Work phase by phase from `IMPLEMENTATION_PLAN.md`; tick phases there.
- Every change gets a `CHANGELOG.md` entry under `[Unreleased]`.
- **No own.audio internals**: no references to closed repositories, internal hosts, team IDs or
  credentials. Comments explain why, for an outside reader.
- own.audio is one server among the others, never a funnel.
- **Keep it small** (the plan's principles): no third-party dependencies without a strong
  reason; server clients by hand; system decoders only — no VLC/FFmpeg, the server transcodes
  what iOS can't play; no cross-platform frameworks. Check the app's size on every release.
- A feature a server lacks is hidden, not broken: the screens ask the source what it can do.
- **Never lose a position.** Every position change is written to disk before it is sent;
  anything that touches progress reporting is tested offline and with a dead server.
- Code copied from `own-audio/music-ios` keeps its file names; a fix there is ported here by
  hand and noted in the changelog.

## Build

```bash
xcodegen generate                       # after changing project.yml; the .xcodeproj is not committed
(cd Packages/AudiobookshelfKit && swift test)   # live tests too with AUDIOBOOKSHELF_HOST/USERNAME/PASSWORD set
(cd Packages/OwnAudioKit && swift test)         # live tests too with OWNAUDIO_HOST/EMAIL/ACCOUNT_PASSWORD set
(cd Packages/BookLibrary && swift test)
(cd Packages/PlayerEngine && swift test)        # plays generated fixtures through a real AVPlayer
xcodebuild -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Editor shows "no such module" on code that builds? Run
`xcode-build-server config -project OwnAudioBooks.xcodeproj -scheme OwnAudioBooks`
(`buildServer.json` is gitignored).

## Tests against real servers

Credentials live in the gitignored `test-servers.local.env` (the variables are listed at the
top of `scripts/test-servers.sh`); never commit them. `scripts/test-servers.sh` runs the live
client tests and the UI tests against each server; `ONLY_TESTING=<test>` runs one UI test.
UI tests need `-test-timeouts-enabled YES -default-test-execution-time-allowance …`, or a stuck
query hangs for ever.

- Audiobookshelf tests use a throwaway user: play sessions and progress writes change the
  account's listening history.
- A throwaway Audiobookshelf: see the plan's "Test servers".

## Release

TestFlight: `scripts/testflight.sh` (needs `DEVELOPMENT_TEAM` in the gitignored
`release.local.env` and the account signed in to Xcode). The Team ID stays out of `project.yml`
because the repo is public. App icons must have no alpha channel.

## Layout

- `App/OwnAudioBooks/` — the app.
- `Packages/AudiobookshelfKit/` — Audiobookshelf client, Foundation only.
- `Packages/OwnAudioKit/` — own.audio's own API (`/api/v2`), Foundation only.
- `Packages/ServerSupport/` — answer cache and offline switch.
- `Packages/BookLibrary/` — models, `BookSource`, the adapters, server store, addresses.
- `Packages/PlayerEngine/` — `SpokenEngine` + `PlayerCore`; knows books by an opaque id,
  nothing about servers.
