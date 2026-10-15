# App Store listing

Text per language (`en-US/`, `cs/`), in the store's fields; screenshots come with B12 from
`scripts/app-store-screenshots.sh`. `scripts/app-store-upload.swift` sends it all.

Store details that live in App Store Connect:

- **Category:** Books.
- **Age rating:** 4+ (the app shows whatever the user's own server holds).
- **Price:** free, no in-app purchases.
- **App privacy:** Data Not Collected. The app sends nothing to anyone but the servers the
  user adds (and Apple or Google for a sign-in the user chooses); see `PRIVACY.md`.
- **Privacy policy URL:** https://github.com/own-audio/book-ios/blob/main/PRIVACY.md
- **Support URL:** https://github.com/own-audio/book-ios/issues
- **Marketing URL:** https://www.own.audio
- **Review notes:** no account is needed to try the app: the welcome screen's "Try the Demo
  Library" signs in to the public own.audio demo server (demopi.own.audio) by itself, which
  holds public-domain books. For an Audiobookshelf server the reviewer needs one of their own.

Limits: name and subtitle 30 characters, keywords 100, promotional text 170, description
4000.

Downloads, Sign in with Apple and Google, and CarPlay are left out of the description until
they ship (B5, B6, B10).
