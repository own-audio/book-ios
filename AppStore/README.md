# App Store listing

Text per language (`en-US/`, `cs/`), in the store's fields; screenshots taken by
`scripts/app-store-screenshots.sh` from a server whose books may be shown publicly, framed with
their captions (`captions.json`) by `scripts/marketing-screenshots.swift`.
`scripts/app-store-upload.swift` sends it all. The three apps' listings are made the same way,
so they read as one family: own.audio Music's is the model.

Store details that live in App Store Connect:

- **Category:** Books.
- **Age rating:** 4+ (the app shows whatever the user's own server holds).
- **Price:** free, no in-app purchases.
- **App privacy:** Data Not Collected. The app sends nothing to anyone but the servers the
  user adds (and Apple or Google for a sign-in the user chooses); see `PRIVACY.md`.
- **Privacy policy URL:** https://github.com/own-audio/book-ios/blob/main/PRIVACY.md
- **Support URL:** https://github.com/own-audio/book-ios/issues
- **Marketing URL:** https://www.own.audio
- **Review notes:** `review_notes.txt`. Demo account: guest@demo.own.audio (the welcome
  screen's "Try the Demo Library" signs in to it by itself).

Limits: name and subtitle 30 characters, keywords 100, promotional text 170, description
4000.

CarPlay is left out of the description until it has been checked on a CarPlay screen. Ebook
narration is left out too: it spends the family's credit, and appears only on a server that
offers it.
