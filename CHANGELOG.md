# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- own.audio and Audiobookshelf no longer sign the phone out after the app restarts. Saving a
  server for any other reason (an address it learned on a new network, the libraries, a chosen
  address) wrote back the tokens from when the app started, over the ones refreshed since; at
  the next launch the app presented a refresh token already rotated, which own.audio treats as
  theft and ends the device's sign-in. `ServerStore.update` now keeps the stored tokens unless
  the save is a new sign-in (`signIn: true`). Test: `ServerStoreTokenTests`.

### Added

- Account, listening and colour, ported from own.audio Music:
  - Delete Account on an own.audio server's page (Settings → the server → Account): asks once,
    then deletes the account and everything it added on the server (`DELETE /api/v1/users/me`)
    and the server from this iPhone. The server's last admin is told to hand over first; the
    public demo's shared account is refused by the server and the app says so. App Store
    guideline 5.1.1(v): an app that can create an account (own.audio's Apple and Google
    sign-in can) must let it be deleted in the app. Never offered for Audiobookshelf, whose
    accounts the server's admin makes.
  - Listening, on the same page: time listened in a week, month, year or ever, days in a row,
    audiobooks finished, minutes per day as a chart, by kind and the most played, from every
    own.audio app on the account (`/api/v1/stats/me`). The family's admin also sees each
    member's total, or "Private" for those who don't share it (`/api/v1/stats/family`);
    everyone else gets a switch to share theirs with the admin, on servers that say whether it
    is shared (1.0.0-beta.49 and later). `OwnAudioKit/Account.swift` is Music's file;
    `getV1` takes a query. `BookLibrary` passes the calls through `OwnAudioSource`. Tests:
    `AccountTests`.
  - Accent Colour in Settings: the app's brown or one of ten others (pink in the place of
    Music's brown), for buttons, links, progress and what's playing; alerts and menus follow.
    The icon, the widgets, the own.audio mark and the audiobook colour in the family's storage
    bar keep the brown. Places that drew in `Theme.Colors.accent` or `Color.accentColor` now
    draw in the tint.
  - The family's credit is only shown, without telling who tops it up: an app that may not sell
    anything shouldn't point to where it is sold.
  - UI test `DemoTests.testSettingsOnTheDemo`: the welcome screen's demo, the colours,
    Listening, and the delete dialog (cancelled).
- An own.audio book plays on a network that blocks cloud storage (a company firewall, say).
  own.audio's stream link redirects to the file in storage; when that host does not resolve,
  refuses or resets the connection, fails TLS, or a proxy in between answers 403, 407 or 451,
  the same link is tried once more with `route=proxy`, which the server (1.0.0-beta.43 and
  later) redirects to its media proxy on its own domain; older servers ignore it. That the
  proxy worked is remembered per server and network (the network monitor's signature) for a
  week, so later streams and downloads go straight to it; if the proxy fails there and
  storage works again, it is forgotten. A 403 from the server itself is still an expired link
  and is renewed as before, and no network at all is still a gap in the signal. It applies to
  the player streaming a file itself, the look-ahead window's chunks, the listening cache and
  downloads; only own.audio stream links are ever changed. The decision is `StorageRoute` and
  `ProxyMemory` in `PlayerCore`, copied as is to own.audio Podcasts and own.audio Music.
  `StorageRouteTests`, and `StreamWindowTests` with storage blocked by a failing name and by a
  proxy's 403/451.
- The next minutes of a streamed book are kept on the phone, so a tunnel or a car with no
  signal goes unheard. A streamed file plays through `StreamWindow`, an
  `AVAssetResourceLoaderDelegate` that serves the player from a sparse file per part and
  fetches what is missing with HTTP Range; a prefetcher keeps the playhead plus the chosen
  minutes on disk (estimated from size and duration, with 20 % margin), in a burst of 1 MB
  chunks once the stretch ahead has shrunk by a quarter, then the radio is idle; near the end
  of a file it fetches the start of the next. Beyond the window the player waits for the
  playhead, so a long file is not fetched whole on mobile data. Which bytes are on disk is kept
  beside them, so a relaunch or a later replay uses them. A link the server refuses (401/403)
  is renewed once and shared by the fetches waiting for it. The player is told the type from
  the file's first bytes, else the server's content type (M4B/M4A, MP3, FLAC, WAV, AIFF); a
  server that ignores Range, or a type the player can't be told, streams as before. The window
  shares the listening cache's 1 GB cap (its stretches go first, the book playing keeps its
  own), and works on any network, also with Wi-Fi-only downloads. Settings → Streaming → Keep
  Ahead: 5, 10 or 15 minutes, 10 by default; 5 with Low Data Mode. Saver streams (a transcode
  or HLS made as it plays) are not kept. The player shows how much is saved ahead ("8 min
  saved"). `StreamWindowTests`, `PartLocatorTests`.
- A gap in the signal longer than what is saved ahead is ridden out instead of ending
  playback. When the player runs out of bytes with no network (or a server that does not
  answer), it shows "No signal — waiting" in the player and the mini player, not an error; the
  position is saved as at a pause and the wait is not counted as listening. The player itself
  is held rather than paused, since a paused audio app is suspended in the background and could
  not come back by itself. The window keeps trying, 2 s doubling to 30 s; a stream that failed
  (a Saver transcode, HLS) or a file not on the phone gets a fresh link on the same backoff,
  where it used to try once and stop for good. When the network is back it plays on by itself
  (smart rewind applies), unless the listener paused meanwhile. In Offline Mode a file that is not on the phone still stops with a message,
  since no signal is coming. `SignalWaitTests` (the state machine, and a gap with no network
  and with a dead server, played through the window).

### Fixed

- Covers from an own.audio server load again. The library comes from the synced snapshot, and
  a book that never changed kept the image link it came with: signed for a week or two, and
  built for the address the server had then (a home address, before a tunnel gave it a public
  one). A cover that does not load now asks the server for the book's current link once
  (`BookSource.currentCoverURL`).
- A file that cannot be played asks the server for one fresh link, then shows the error. It
  asked again on every failure, without end (found in own.audio Podcasts, which has the same
  engine; ported with its test).
- The look-ahead window could fetch a whole file at the start: the player picks up its read
  where the last one stopped, beyond the window's end, and such a read was taken for a lookup
  and not held back. A read that continues the last one is held back now; reads within the
  player's own forward buffer never are, and an empty playback buffer counts as a stall at once
  (the player's own state can take seconds), so held-back bytes never starve it.
- A request the player let go of was logged as a failure of the window.

### Changed

- A file on the phone is played from the phone, file by file, every time. One locator decides
  for each file of a book — the download, then the listening cache, then the stream — at play,
  on a seek into another file (which used to reuse the link from the start), and when the file
  before ends. A partly downloaded book plays its downloaded files from disk, also online, and
  with no network it plays what is on the phone: a file that is not there stops with "This
  part of the book is not on this iPhone" instead of a player error. A download that finishes
  while the book plays is used at once for a file still to come; the file playing now switches
  at the next pause or seek, never mid-sentence. The listening cache fetches the next file
  whether the one starting was on the phone or not (it used to stop at the first streamed one).
  `PartLocatorTests`, `LocalCopyTests`.

- Less work in the background and while nothing changes:
  - narration jobs are asked about 4 s after a change, then half as often each time nothing
    moved, up to once a minute; the polling stops when no running job's server is set up, and
    `narrations.json` is written only when something changed;
  - other devices' positions are fetched every three minutes only while the app is in front;
  - Home reads its shelves again after a pause only when it is on screen, else when it is seen
    again;
  - the app counts as in the background until a window is active, so a launch by CarPlay, a
    download or a background refresh opens no event stream and starts no polling (CarPlay
    plays as before);
  - download progress reaches the main thread at most twice a second per file.
  `BatteryTests`.
- Network changes are settled before the app acts on them: three seconds after the last path
  update, and a change that only reorders the same interfaces is none. In the background (a
  car handing over between cells) only queued positions are sent; the addresses are raced again
  when the app comes to the front. The remembered address per network is keyed by the sorted
  interfaces now, so each network is raced once more after the update. `NetworkChangeTests`.
- The Continue Listening widget was redrawn every minute while a book played: the check for "no
  change" compared the snapshot's time too, so it never matched. Only the books are compared
  now, and the widget follows play, pause and a change of book instead of the position ticks.
  `WidgetSnapshotTests`.
- Fewer progress reports and file writes while a book plays. Every 10 s the position is
  written to one file (the queue in `PendingProgress`) instead of five places and a request.
  The server gets it once a minute while playing, and at once on pause, seek, chapter change,
  stop, a book change, the end and going to the background, so the phone's radio can sleep in
  between; Audiobookshelf's play session is synced at the same pace. The resume point, the known
  positions and the last book are written at the same moments (`ProgressReporter`,
  `CheckpointedResumeStore`). A kill between two of them loses nothing: the queue is replayed
  at the next launch. A dead server is tried once a minute, not on every tick.

### Fixed

- A pause while a report was on its way could drop the paused position from the queue when the
  report came back; it is now sent right after.

### Tests

- `ProgressReporterTests`: the minute cadence, the reasons sent at once, offline (nothing tried,
  everything on disk), a dead server (tried once a minute, position kept), a refused sign-in,
  an ended play session, a pause during a slow report, and recovery after a kill.

### Removed

- The Live Activity. The lock screen showed two players, the system's Now Playing controls and
  the app's own activity below them; only the system's stays, also in the Dynamic Island and on
  CarPlay. Its updates every 15 s while playing and its cover fetches go with it. The
  Continue Listening widget, the `ownbook://play/` links and the Siri phrases are unchanged.

### Tests

- CarPlay unit tests (`UnitTests/CarPlayContentTests`, a new unit-test target hosted by the app):
  the start list, Continue Listening online (the server's shelf) and offline (started, not
  finished), the rate button's steps, untitled chapters and how a list is built. What CarPlay
  shows moved out of the scene delegate into `CarPlayContent`, as in the podcasts app.

### Fixed

- The speed shows as the listener reads it, everywhere (player, speed sheet, Settings):
  "1.75×" instead of "1.8×" (`%.2g` kept two digits), "1.5×" instead of "1.50×", and with the
  phone's decimal sign ("0,75×" in Czech). UI test `PlayerSpeedTests` (demo library): 1×, 0.75×, 1.75× on the button and in the sheet.

### Fixed

- Settings → Add a Server closed its sheet at once: the sheet hung on the servers' section, not
  on the Settings screen. It is shown by Settings now. UI test
  `ServerPageTests.testAddServerSheetStaysOpen` (failed before the fix in the music app).

### Fixed on iOS 27

- The Search tab had no search field on iOS 27: iOS no longer put the field into the tab by
  itself, so there was nothing to type into (found in the podcasts app). Selecting the tab now
  opens the field, with the keyboard (`tabViewSearchActivation(.searchTabSelection)`), on
  iOS 26 as well.

### Settings the same in all three apps

- The servers are listed in Settings, as in the podcasts app: a tap opens the server's page, a
  swipe removes one after asking ("Remove ‹name›?"), the selected server has a checkmark, and a
  refused sign-in shows on its row. The page has **Use This Server**, Check Now, Sign In Again,
  Family and Devices for own.audio (moved off the Settings screen), **Name** (rename), the
  library, the addresses, Library on This iPhone and **Remove Server**, in the order the other
  apps use. The Servers screen, its rename alert and its long-press menu are gone.
- Settings in the same order as the other apps: Whole Library When Offline joins Downloads,
  Skip Back comes before Skip Forward, On Mobile Data is under Streaming, and Logs has the
  links' colour.
- Czech: "Původní" for Original, "Odebrat ‹name›?" for removing a server.
- UI tests follow the new layout; `ServerPageTests.testRenameAndRemoveOnTheServerPage`.
- The "Remove ‹name›?" question is asked by the Settings screen itself, as in the podcasts app:
  attached to the servers' section it didn't show on iOS 26.5, and a swipe removed nothing.

### Added

- The last book comes back after a relaunch: the mini player shows it with its cover and time left,
  and a tap plays it from where it was. It is loaded only then, so a launch never opens a play
  session on Audiobookshelf for a book nobody pressed play on. Stop and the end of the book clear
  it. Built in the podcasts app first; UI test: played, paused, killed, started again.
- An AirPlay button among the player's tools (`AirPlayRouteButton`, from the music app through the
  podcasts app).

- Server logos: own.audio's mark, and each Audiobookshelf server's own icon, loaded from the server
  and kept (the app ships no Audiobookshelf artwork), in the server list and on the server's page.
- The server's page lists its addresses and where each came from (added with, from the server,
  added by you); Add Address takes another (a home network, a VPN such as Tailscale), swipe
  removes one, and Connection chooses Automatic — the fastest that answers as this server on each
  network — or one fixed address. The model had both already; now there is a screen, as in the
  podcasts app. UI test.

- Favourites (own.audio): the badge on a favourite book's cover, now set from the library copy
  on the phone (it was never shown), and Favourites in the Library's filter, offline too. The heart
  on a book's page updates both at once. UI test: marked, filtered, badge, unmarked again.
- Settings → Logs: what the app logged since it started, to read and to share as a text file with
  a bug report; nothing is sent anywhere unless shared. Copied from the podcasts app. UI test.
- Background refresh: iOS may wake the app about once an hour to bring the own.audio library copy
  up to date and send any position still waiting. iOS decides whether it runs.

### Fixed

- The Live Activity's skip buttons show the chosen intervals; they always showed 15 s back and 30 s
  forward. The intervals travel in the activity's state (optional, so an activity from an older
  build still decodes).
- The player's tools share the row's width, so all five fit on an iPhone; at fixed gaps five would
  have run past the edge. UI test: every tool on screen.
- UI tests launch through `launchChecked()`, which makes sure the app got its arguments: iOS can
  hand a test a prewarmed copy of the app, started without them — in the device's language and
  without `-uiTestReset`. Playback and download settings are reset on `-uiTestReset` too. Copied
  from the podcasts app, where both were found.

- Audiobookshelf book libraries: the server's page lists them and which one the app shows, to
  choose there; with several, each is its own entry in the server switch on Home ("server ·
  library"), and the names are kept for offline.
- Every downloaded book says which server it came from.
- An Offline Mode switch on Home, beside Settings, as in the music app.
- A Downloads tab: every downloaded book, from every server, one tap from anywhere (it was
  under Settings before).
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

- Sign in with Apple and Google for own.audio servers that offer them, on the welcome
  screen, in Add Server and in Sign In Again; Devices under Settings — every device signed in
  to the own.audio account, this one first, sign one out or everywhere (B5).
- The Library's series, authors, narrators and collections links show before the books have
  loaded.

- Downloads: a book on the phone through a background session that survives the app being
  killed, Wi-Fi only, a storage limit with finished books going first; Offline Mode and the
  no-network state show and play what is on the iPhone; positions reported when the network is
  back (B6).

- Positions from other devices: a question before playing when another device went on with
  the book ("Continue from Car?"), and positions refreshed at foreground and while playing (B7).

- Import a book from the phone to an own.audio server: files or a folder from the Files app,
  the form filled from the tags, uploads in the background that survive the app being killed,
  one book at the end, never two (B8).

- The family on an own.audio server (Settings → Family): members, storage, credit where the
  server charges, invitations for admins, joining another family with a code. A book of your
  own is shared with the family or kept to yourself from its menu. With more than one server,
  a menu on Home switches between them (B9).

- Downloads as sets: the arrow above a series, an author's books or a collection downloads
  them all, with a count on the way. The Downloads screen groups by server and retries failed
  downloads together. Settings → Whole Library When Offline lists an own.audio server's whole
  library offline from the copy on the phone, the books not downloaded greyed out. Settings →
  Servers → ⓘ shows a server's account and address, checks the connection, and for own.audio
  the size of the library on the phone, when it was updated, and Update Now (B9b).

- CarPlay: Continue Listening, Downloads, Library, Series and Authors on the car's screen, the
  system Now Playing with the speed on its rate button and the chapters behind Up Next. The car
  never asks where to continue; the newer position wins (B10).

- iPad: the Library tab is a sidebar — All Books, Series, Authors, Narrators, Collections,
  Downloads — beside the open section (B10).

- Siri and Shortcuts: "Play *title* in own.book" and "Continue listening in own.book", matched
  against the library (the downloads when offline); in English and Czech (B10).

- A Continue Listening widget, small and medium: the book playing and the last ones started,
  with their covers and how much is left; a tap opens the app on that book (`ownbook://play/…`).
  The app writes the snapshot into an App Group; the widget needs no network or sign-in (B10).

- A Live Activity while a book plays: cover, title, chapter, how far and how much is left on the
  lock screen and in the Dynamic Island, with play/pause and the skip buttons working without
  opening the app (B10).

- Narrate an ebook, on own.audio servers that offer it: an EPUB, MOBI or text file read aloud by
  an AI voice into an audiobook — pick the languages and the voice, see the server's character
  count and price against the family's credit, start, and follow the job in the Library; the book
  arrives when it is done (B9c).

- Tests: misuse (wrong sign-ins, hammered player, stop while loading, restless navigation and
  odd searches, interruptions, the app killed mid-download), the main screens at the largest
  text size, cold-start timing (B11).

### Fixed

- The app icon set's manifest named no files, so no icon was compiled into the archive.
- Swiping a bookmark in the player's Bookmarks sheet showed bare icons; the buttons now say
  Delete and Rename.
- Streaming stuttered on a slow server, on Audiobookshelf and own.audio alike: the player now
  keeps three minutes of a file fetched ahead, shows "loading" while it waits for the network
  instead of playing gaps, and keeps what it streams on Wi-Fi in a listening cache (a gigabyte,
  the oldest let go first) — the next file of the book starts from disk, and a book heard once
  plays again without the network. Separate from downloads, which it never counts as.
- Offline with nothing downloaded, Home said the server's library was empty; it now says what
  offline shows.
- Stop in the player left the book in the mini player; it now lets the book go everywhere.
- The Live Activity showed a grey square instead of the cover: the cover's name was fixed at the
  activity's start, before the cover had loaded. It now travels in the state and is filled in
  as soon as it is there.
- A retried request to an own.audio server (an import after the app was killed, say) was refused
  as "used for a different request": the JSON keys came out in a different order each time. They
  are sorted now.
