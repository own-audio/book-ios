# Implementation plan

**own.audio Books** — a native, open-source audiobook player for iPhone and iPad that plays
from **own.audio** and **Audiobookshelf** servers, side by side. Swift 6, SwiftUI, iOS 18+.
MPL-2.0.

It is the second app in a family that began with own.audio Music (`own-audio/music-ios`), and
it is built in the same shape: the same repository layout, the same rules, the same test and
release scripts. Code that the music app already has — the own.audio API client, the Keychain
server store, address racing, the offline change queue, Now Playing and the sleep timer — is
copied here rather than shared through a package, so each app stays self-contained and can be
built from one checkout. Written 2026-10-15.

## Principles

- **One app, many servers.** The same screens for an own.audio server and an Audiobookshelf
  server; a feature a server lacks is hidden, not broken. own.audio is one server among the
  others here, with extras where its server offers them, never a funnel.
- **A book is not a song.** Speed, chapters, one position per book that follows you between
  devices, a sleep timer that knows where the chapter ends, skip buttons instead of next/previous,
  smart rewind after a pause. The player is built for spoken audio from the start, not adapted
  from the music engine.
- **Local player, server as the brain.** The library lives on the phone (catalogue, covers,
  chapters), downloads play with no network, and what you did offline — positions, finished
  marks, bookmarks — is queued and sent when the server is back.
- **Robust by default.** Automatic connection and quality choices, one visible setting for
  mobile data, a position saved every few seconds and never lost. A player that loses your place
  in a 30-hour book is the worst outcome.
- **Small and native.** No third-party dependencies without a strong reason, server clients
  written by hand, system decoders only (no VLC/FFmpeg — the server transcodes what iOS can't
  play), no cross-platform frameworks. Watch the app size on every release; the music app is
  about 2.6 MB.

## Decisions

1. **AVPlayer, not AVAudioEngine.** The music app decodes with its own Core Audio decoder for
   gapless playback. Books need none of that; they need speed with pitch correction
   (`AVAudioTimePitchAlgorithm.timeDomain`), HTTP range requests, and HLS — Audiobookshelf's
   transcodes are HLS playlists, which AVPlayer plays and AVAudioEngine does not. One
   `AVPlayer` with the book's files as a timeline, loaded one item at a time, is the whole
   engine. This is the `SpokenEngine` of the strategy; `PlayerCore` (Now Playing, sleep timer,
   resume store, file cache) is copied from the music app and extended.
2. **One timeline per book.** A book is a list of files with durations; the engine and every
   screen speak *book time* (milliseconds from the start of the book) and convert to
   (file, offset) only at the edge. Chapters, bookmarks, the scrubber and the sleep timer all
   use book time. own.audio's `Progress` carries both `position_ms` and `file_id +
   file_position_ms`; Audiobookshelf uses whole-book seconds. Both map onto the same model.
3. **Chapters from the file when the server has none.** own.audio does not extract chapters
   from M4B/ID3 yet (narrated books have them, uploaded ones usually don't). AVAsset reads the
   embedded chapter markers of an M4B on the phone — from a download, or over range requests
   from a stream — so the app shows chapters wherever the file carries them. Server chapters win
   when present.
4. **Audiobookshelf media links carry the token in the query**, as the server intends
   (`?token=`), because AVPlayer cannot send a header. Access tokens last one hour and a book
   lasts longer: when an item fails with 401 the engine recreates it at the same position with a
   fresh token. Checked first in B1 (whether a stream that is already open survives expiry).
5. **Progress is written locally first, every time**, then sent. own.audio: `PUT
   /me/progress/book/{id}` with the client clock, or `/sync/push` in a batch when offline.
   Audiobookshelf: a playback session (`/api/items/{id}/play`, `/api/session/{id}/sync`) while
   online so listening stats count; local sessions sent with `/api/session/local-all` after
   offline listening. Bookmarks are online-only on own.audio (not in `/sync/push`) and keyed by
   time on Audiobookshelf; the app queues both the same way and replays them.
6. **Audiobookshelf podcast libraries are hidden.** Podcasts get their own app; this one lists
   only libraries with `mediaType == "book"`.
7. **Copied, not shared.** `OwnAudioKit`, `ServerSupport`, `PlayerCore`, the Keychain server
   store, address racing and the sign-in screens come from `music-ios` as copies. A fix in one
   app is ported by hand to the other; the changelog says when that happens.
8. **Code from own.audio's earlier, closed audiobook app** is used only where its author
   relicenses it under MPL-2.0 for this repository, and only logic that is independent of
   that app's server API: the sleep timer rules, chapter navigation across files, eviction
   policy, resumable range downloads, Siri matching. Nothing branded, nothing tied to v1.

## Layout

- `App/OwnAudioBooks/` — the app (bundle `audio.own.bookplayer`, home screen "own.book").
- `Packages/AudiobookshelfKit/` — Audiobookshelf client, Foundation only.
- `Packages/OwnAudioKit/` — own.audio's API (`/api/v2`), Foundation only; copied from the
  music app and extended with books.
- `Packages/ServerSupport/` — answer cache, offline switch; copied from the music app.
- `Packages/BookLibrary/` — the app's only view of servers: one set of models, the
  `BookSource` interface with capabilities, the two adapters, the server store and addresses.
- `Packages/PlayerEngine/` — `SpokenEngine` (AVPlayer timeline, speed, chapters, skip, smart
  rewind) and `PlayerCore` (Now Playing, sleep timer, resume points, file cache).
- `UITests/` — end-to-end tests against real servers.
- `scripts/` — `test-servers.sh`, `testflight.sh`, `app-store-screenshots.sh`,
  `app-store-upload.swift`, `marketing-screenshots.swift`, copied from the music app.

## What the servers offer

| | own.audio (`/api/v2`, draft until this app ships) | Audiobookshelf 2.37 (verified 2026-10-15) |
|---|---|---|
| Sign-in | `POST /auth/token`: password, refresh (rotating), Apple/Google id token, two-factor, device code; `/.well-known/own-audio` | `POST /login` with `x-return-tokens: true` → 1 h access JWT + 30-day refresh; `POST /auth/refresh` with `x-refresh-token` (rotates); `POST /api/authorize` at launch; OIDC optional |
| Library | `GET /books` (cursor, `contributor_id`, `q`, `sort`); `GET /books/{id}` with `files[]`, `chapters[]`, `series[]`; `/authors`, `/narrators`; snapshot + change feed carry the full records | `GET /api/libraries` (books only), `/items` (page, `sort`, `filter=<group>.<base64>`, `collapseseries`), `/series`, `/authors`, `/narrators`, `/collections`, `/personalized` (home shelves), `/search` |
| Series, collections | On the book only (`series[]` with fractional position); no resource; built client-side | Resources with ids; narrators have no ids |
| Chapters | `chapters[]` in ms across the book; often empty for uploads → read from the file | `media.chapters[]` in whole-book seconds with `start`, `end`, `title` |
| Progress | `GET/PUT /me/progress/book/{id}`: `position_ms` or `file_id + file_position_ms`, `finished`, `at`; **per-device positions** (`devices[]`); `/sync/push` offline | `PATCH /api/me/progress/{id}` (`currentTime`, `isFinished`); sessions `/play` → `/sync` → `/close`; `/local-all` for offline; one position per book, `lastUpdate` |
| Bookmarks | `/me/bookmarks` with id and label; online only | `/api/me/item/{id}/bookmark` with `{time, title}`, keyed by time, no id |
| Favourites | `/me/favourites/book/{id}` | none |
| Media | `POST /playback-info` per **file** (`kind: book_file`): direct link (302 to storage, ranges) or transcode (AAC/MP3, `start_ms` per link, 6 h) | `/api/items/{id}/file/{ino}?token=` with ranges (verified 206); transcode = HLS `/hls/{session}/output.m3u8` from a play session |
| Covers | signed `image` link on the record, `w=` sizes, weekly expiry | `/api/items/{id}/cover?width=` — **no auth needed** (verified) |
| Live changes | `/events` SSE → `/sync/changes` | socket.io; otherwise re-read `/api/me` |
| Household | `/family`, members, invites, visibility `private`/`family` | separate users, no sharing |
| Uploads | `POST /uploads` (size required) → `POST /books` | `POST /api/upload` multipart (upload permission) — later |
| Missing | series/collection resources, book search in `/search`, book edit/delete, bookmarks in `/sync/push`, files and chapters in list pages, narration routes in the open document | favourites, ratings, per-device positions, a change feed |

Verified on 2.37.1 and worth knowing: the `ino` of a track is a string (the earlier Mac client
saw numbers on another version — parse both); filters accept standard and URL-safe base64;
`/api/me` returns every `mediaProgress` and `bookmarks` row, which is the whole progress pull;
`personalized` returns `continue-listening`, `recently-added`, `discover`, `listen-again`,
`newest-authors`; metadata strings can arrive mis-encoded from the server (keep the Mac
client's mojibake repair, applied to display only).

## Phases

- [x] **B0: Repository and skeleton.** Done 2026-10-15. `project.yml` (iOS 18, Swift 6,
  iPhone + iPad, background audio, Sign in with Apple entitlement, no team id), the app target
  with a placeholder root view, the UI test target with a launch test, `ServerSupport`,
  `OwnAudioKit` and `PlayerCore` copied from the music app without their music-only parts
  (playlists, smart playlists, identify, the equalizer, scrobbling) — 55 package tests green;
  the scripts renamed for this app and its servers. The Audiobookshelf write paths checked
  with a throwaway user on 2.37.1: `POST /api/items/{id}/play` answers one `audioTracks` entry
  per file (`contentUrl`, `startOffset`, `duration`, `mimeType`) with `playMethod` 0, or one
  HLS track (`/hls/{session}/output.m3u8`, `playMethod` 2) when transcoding; **a new session
  for the same book closes the open one** (its `sync` then answers 404), so the app holds one
  session per book; `POST /api/session/{id}/sync` and `/close` take `{currentTime,
  timeListened, duration}` and answer the text `OK`, and both move the user's progress;
  `POST /api/session/local-all` takes `{sessions:[…], deviceInfo}` with client ids,
  `playMethod` 3, `startTime`/`currentTime`/`timeListening`, answers per-session
  `{success, progressSynced}` and moves progress; `PATCH /api/me/progress/{id}` and
  `/progress/batch/update` work as described; bookmarks create, patch and delete by `time`;
  socket.io (engine.io 4) accepts `42["auth", <jwt>]` and answers `init`; access tokens last
  3600 s. Still open: whether an open stream survives the token's expiry (an hour-long test,
  in B1).

- [x] **B1: AudiobookshelfKit.** Done 2026-10-15; 27 unit tests on a stubbed session and 7
  live tests against a 2.37.1 server (sign-in, rotation, the library, progress, bookmarks,
  sessions, a transcode). A hand-written client with the same shape as `OwnAudioKit`: `status`,
  sign-in with `x-return-tokens`, a `TokenSession` with single-flight rotating refresh (the
  JWT's `exp` is the expiry; a pre-2.26 token has none and is never refreshed), `authorize`,
  `me`, `signOut`; book libraries only; items paging with sort and URL-safe base64 filters;
  item detail (`expanded=1`, progress included); series, authors, narrators, collections,
  `personalized`, search; progress read, patch, batch and delete; bookmarks by time; play
  sessions (`play`, `sync`, `close`, `local-all`); file, media and cover URLs with the token
  in the query; `Mojibake.repair` for UTF-8 read as Latin-1. Library reads are cached and
  answer offline; search, `me` and sessions are not.

- [x] **B2: BookLibrary.** Done 2026-10-15; 17 unit tests on the mappings, and one live test per
  server kind that drives the whole `BookSource` (sign-in, shelves, books, detail, people,
  series, search, progress, bookmarks, favourites, a plan whose first part answers a range
  request, reports, a smaller stream, clearing) against a 2.37.1 Audiobookshelf and a beta.20
  own.audio. Models in book time (`Book` with `files` as a timeline and `chapters` with ends,
  `Progress` with device positions, `Bookmark`, `Shelf`, `SeriesSummary`, `PlayPlan`,
  `PlaybackReport`), `protocol BookSource` with `Capabilities`, `ChangeFeedCatalogue` and
  `LiveLibraryUpdates`. `AudiobookshelfSource`: lists from the server (a text query goes to its
  search), `personalized` shelves, a series' books through the filtered items list (its own
  record has none, and a row filtered by a series carries that series as one object), bookmarks
  keyed by time, a play session per plan (HLS when a smaller stream is asked for), mojibake
  repaired at the edge. `OwnAudioSource`: the catalogue on the phone from the snapshot and
  change feed (`contributor`, `book`, `favourite.book`, `progress.book`, `bookmark`), browsing,
  series and search over that copy, a signed link per file asked for at once, per-device
  positions from the server with the copy as the fallback offline. `ServerStore` (Keychain, one
  item), `ServerRecord` with kinds `audiobookshelf` and `ownAudio`, `TokenSessions` keeping one
  token session and one catalogue per server across rebuilt sources, address scopes and racing,
  `ServerSetup` for both sign-ins (password, Apple/Google id token, two-factor, demo account).
  `OwnAudioKit` gained the book, progress, bookmark and `playback-info(kind:)` calls.

- [x] **B3: SpokenEngine.** Done 2026-10-15; 44 package tests, among them an engine suite that
  plays an 8-second two-file book through a real `AVPlayer`: periodic and pause reports with
  listened time, a seek across files, chapter buttons, speed at 3×, the end of the book, the
  end-of-chapter stop, smart rewind off, a failed link replaced through `partRefresher`, and a
  failure shown when there is none. `BookTimeline` (parts end to end, locate and position,
  chapters with grace on "previous", skips clamped), `SmartRewind` (0 s under 10 s of pause,
  3 s, 10 s, 20 s, 30 s after an hour), `SpokenBook`, `EmbeddedChapters` (an M4B's chapter
  track read on the device, in the file's own locale, moved to book time), and `SpokenEngine`
  itself: one `AVPlayerItem` at a time with `timeDomain` pitch, rate 0.5–3.0 in 0.05 steps,
  `.spokenAudio` + `.longFormAudio` session, interruptions and unplugged headphones pause, Now
  Playing with skip intervals and chapter next/previous (`PlayerCore` gained `configureSkips`
  and `useSpokenAudioSession`), positions reported every 10 s of listening and on pause, seek,
  chapter, stop, finish and teardown, remembered locally through `ResumeStore`, links refreshed
  before a part whose link is about to run out. Transcoded HLS parts play as any other URL.

- [x] **B4: The app.** Done 2026-10-15; the UI smoke suite (add server, library, detail, play,
  skip, speed, bookmark, chapters, sleep timer, pause, progress shown, reset) and the
  wrong-password test pass against a 2.37.1 Audiobookshelf and the own.audio demo, the launch
  test on every build. `AppModel` (servers in the Keychain, address racing, own.audio
  catalogues synced and kept between launches, positions written to disk before they are sent
  and flushed at launch, on foreground and on every network change, a reset that stops the
  engine without reporting and drops what was queued), onboarding and Add Server (the address
  tried as own.audio, then Audiobookshelf; https then http; two-factor sheet; the demo),
  Servers (select, check, rename, sign in again, Audiobookshelf library picker, remove), Home
  (the server's shelves), Library (grid/list, sort, filters, series, authors, narrators,
  collections where offered, paged), book detail (chapters, files, bookmarks; play/resume;
  mark finished; reset), Search, the player (book bar with time left at the current speed,
  chapter scrubber, skips, chapter buttons, speed, sleep timer with end of chapter and book,
  chapters, bookmarks), the mini player, Settings (skip intervals, default speed, smart
  rewind, mobile data). Known: titles mis-encoded on the server as Latin-1-read Windows-1250
  ("èást" for "část") are shown as the server has them; the repair covers UTF-8 misreads only.

- [ ] **B4b: The look.** The design of own.audio's audiobook app, as its design system has
  it: the audiobook brown as the accent (`#7A4A2B`, `#D7A97C` in the dark), Apple-like
  neutrals (`#F7F7F8` / `#0C0C0E` alternate backgrounds, `#6E6E73` / `#98989D` muted), the
  4/8/12/16/24/32 spacing scale, radius 12 for cards and covers, 16 for the mini player, 28 for
  sheet tops, no shadows — depth from materials. Cards with the favourite, family and download
  badges in the corners and a progress bar below; Home with a greeting and 140-pt rails; a
  list with 56-pt covers; the detail's 120-pt cover beside a bold title, a capsule Play button
  whose fill is the progress, metadata rows with symbols; the player's 260-pt cover, muted book
  bar over the accent chapter slider, 64-pt play glyph, step buttons, labelled bottom tools;
  the mini player on material. The welcome screen with the own.audio mark, the rotating
  wordmark and the hero artwork. **One app icon** (done 2026-10-15, `Design/`): the music
  app's construction — the five family figures in their colours — with a closed book in brown
  in the centre, rendered by `scripts/render-icons.mjs`; the same artwork as `AppLogo`.
- [ ] **B4c: English and Czech.** Every string through the String Catalog
  (`Localizable.xcstrings`, `InfoPlist.xcstrings`): English as the source, Czech complete, one
  Czech term per concept as the other own.audio apps use them (kapitola, záložka, rychlost,
  časovač spánku, knihovna, série, vypravěč…). Plurals as CLDR categories. No string left in
  code outside `String(localized:)` or a SwiftUI literal; brand names as `verbatim`. Checked
  by running the UI suite in Czech.
- [ ] **B5: Sign-in with Apple and Google, two-factor, sessions (own.audio).** Copied from the
  music app: `AppleSignInButton` (AuthenticationServices, `identityToken` as the jwt-bearer
  assertion, full name on first sign-in), `GoogleSignInButton` (`ASWebAuthenticationSession`
  with PKCE, no SDK, the code exchanged for an `id_token` on the phone; needs a Google iOS
  OAuth client for this bundle id, which is public by design), `TwoFactorView` for
  `mfa_required`, sign-in again on `signedOut`, Devices (sessions) with sign out everywhere.
  Buttons appear only when discovery lists the provider. Server operators enable this by
  adding the bundle id and client id to their allow-lists; the README says how.
  Audiobookshelf OIDC: `ASWebAuthenticationSession` to `/auth/openid` with the
  `audiobookshelf://oauth` redirect and PKCE, shown only when `/status.authMethods` contains
  `openid`; verified only once a test server with an identity provider exists — until then it
  stays off.
- [ ] **B6: Downloads and offline.** Background `URLSession` per file with range resume,
  byte-weighted progress on the cover, Wi-Fi-only, a storage cap with oldest-finished-first
  eviction that never evicts the playing book, per-book and total sizes, delete. Covers,
  chapters and the file list are cached at download time. Offline mode (automatic from the
  network monitor, plus a switch): shelves show downloaded books, playback refuses what is not
  complete with a clear message. Offline changes: positions, finished marks, bookmarks and
  favourites go to a `PendingChanges` store and are replayed in order — own.audio in one
  `/sync/push` (bookmarks one by one), Audiobookshelf with `local-all` sessions and
  `progress/batch/update`. Progress conflict: a newer position elsewhere wins and the app says
  so ("Moved to 4:12:08 from your iPad"). Killed-mid-download and dead-host tests.
- [ ] **B7: Live updates and other devices.** own.audio: `/events` in the foreground triggers a
  feed sync; the `devices[]` of a book's progress become "Continue from the car (40:02)?" when
  another device is ahead. Audiobookshelf: `/api/me` re-read on foreground and every few
  minutes while playing, `lastUpdate` compared; socket.io (`user_item_progress_updated`,
  `item_added/updated/removed`) over `URLSessionWebSocketTask` with a hand-written engine.io
  handshake if the polling proves too slow — it is the only signal for deletions.
- [ ] **B8: Import from the phone (own.audio).** Document picker for M4B, MP3, M4A, FLAC and
  folders; `AVURLAsset` prefill of title, author, narrator, duration and embedded chapters;
  file order by hand; cover from the file or the photo library; visibility; `POST /uploads`
  with the exact size, the bytes put to storage by a background session that survives the app
  going away, `POST /books` with an `Idempotency-Key` so a retry cannot make two books; a
  failed part is retried, not lost. Mobile-data warning for large files. Audiobookshelf's
  multipart upload later, if asked for.
- [ ] **B9: own.audio extras.** Household: members and pictures, invites, join by code,
  what is shared with the family (visibility on the book, owner only), storage and credit
  summary — copied from the music app's M10. Favourites. Listening stats where a server has
  them (Audiobookshelf `/api/me/listening-stats`; own.audio when it reaches v2). Narration
  (hosted servers that advertise the module in discovery) when its routes are in v2 shape —
  server work first; the app never sells credit.
- [ ] **B10: Platform.** CarPlay (Continue Listening, Library, Now Playing with skip and
  chapter buttons; the entitlement is requested from Apple separately), a Continue Listening
  widget and a Live Activity for the player, Siri App Intents ("Play *title* in own.book",
  matched against the local catalogue), iPad split view. Each one hidden until it works on a
  device.
- [ ] **B11: Polish, accessibility, tests.** The Czech of B4c re-read on every screen, Dynamic
  Type at the largest sizes, VoiceOver labels on every icon button and
  the scrubbers ("12:04 of 49:23"), 44 pt targets, Reduce Motion, both colour schemes. UI test
  suites against each server kind (`audiobookshelf`, `ownaudio`, `demo`): add server, play,
  seek, speed, chapters, sleep timer, bookmarks, download and offline, mobile data, two-factor,
  misuse (wrong sign-ins, hammered player, interruptions, killed mid-download), performance
  (cold start, library of 500+ books), large text. App size measured.
- [ ] **B12: Release.** Icon (its own, not a recolour of the music icon), App Store texts in
  English and Czech, screenshots from the UI test pipeline on a demo server, `PRIVACY.md`,
  `PrivacyInfo.xcprivacy`, TestFlight under `audio.own.bookplayer`, then the App Store;
  listings on Audiobookshelf's third-party apps page and own.audio's site. v2 leaves draft
  when this app ships on it.

Later: Audiobookshelf upload and podcast libraries (the podcast app), ebooks (never — not an
audio app), ratings (Audiobookshelf has none; own.audio does not rate books), Plex, Universal
Links for family invites, Shortcuts in Czech.

## What this app needs from the own.audio server

Tracked in the server's `docs/api-v2-plan.md`; the app hides what is missing until then.

1. Series and collections as resources, or at least `GET /books?series_id=` and a series
   list — until then series are built from the catalogue on the phone, which is fine for a
   household library.
2. Books, authors, narrators and series in `GET /search`.
3. `PATCH` and `DELETE /books/{id}`, file reorder and delete, cover replace (owner only).
4. Bookmarks in `/sync/push`, so a bookmark made in the car offline is not special.
5. `include=files,chapters` on list pages, or the app relies on the snapshot — it does.
6. Chapter extraction from M4B/ID3 at upload; until then decision 3.
7. The narration routes in v2 shape and in the open document, with a `modules` flag.
8. Allow-list entries for this app's bundle id and Google client id on every server that should
   offer Apple and Google sign-in.

## Test servers

Credentials live in the gitignored `test-servers.local.env`; the variables are listed at the
top of `scripts/test-servers.sh`. An Audiobookshelf 2.37 with a few dozen books, series and
narrators, and own.audio's demo servers. A throwaway Audiobookshelf:
`docker run -d -p 13378:80 -v <books>:/audiobooks -v <config>:/config -v <metadata>:/metadata
ghcr.io/advplyr/audiobookshelf`, then create the admin and a book library in its web UI.
