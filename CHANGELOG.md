# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
