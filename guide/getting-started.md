---
title: Getting started
nav_order: 2
description: "The first time you open the app, it asks for one thing: a server. Make an own.audio account, add your own server, or try the public demo library first."
---

# Getting started

The first time you open the app, it asks for one thing: a server. Make an own.audio account,
add a server of your own, or try the app with the public demo library first.

## The first screen

The first screen offers two ways in: an account on own.audio's hosted service, or a server of
your own.

### No server? Use own.audio

The card at the top is for someone without a server. own.audio keeps your audiobooks for you.

- **Create an own.audio Account** asks for **Your Name**, **Email** and a **Password** of at
  least 12 characters (a few words are fine), then **Create Account**. The app signs in to the
  new account straight away. own.audio emails you a link to confirm the address.
- **Sign In** fills in own.audio's address in the form below, for an account you already have.
- **Try the Demo Library** signs in to a shared own.audio server with public-domain books, with no account
  needed. The server is called **own.audio demo** in the app. Remove it in Settings when you
  add your own.

## Adding your server

Under **Or connect your own server**, fill in:

| Field | What goes in it |
|---|---|
| **Server address** | Your server's address, for example `books.example.com`. |
| **User name or email** | own.audio: your account's email. Audiobookshelf: your user name. |
| **Password** | Your password on that server. |
| **Name (optional)** | What the app calls the server. Leave it empty to use the server's own name. |

Then tap **Connect**. The app finds out by itself whether the address is an own.audio or an
Audiobookshelf server.

If you type the address without `http://` or `https://`, the app tries https first and then
http, so a server at home works as you typed it.

Your sign-in stays in the iPhone's Keychain. Both kinds of server give the app a sign-in token
after you sign in, and the app doesn't keep your password.

## Sign in with Apple or Google (own.audio)

When the address you typed is an own.audio server that offers it, **Sign in with Apple** and
**Continue with Google** buttons appear under **Connect**, with the note "With your own.audio
account." They never appear for an Audiobookshelf address. The sign-in happens on Apple's or
Google's page, and the app passes the result to your server.

## Two-factor codes (own.audio)

If your own.audio account has two-factor sign-in turned on, a **Two-Factor Sign-In** screen
opens after **Connect**. Type the six-digit code from your authenticator app, or one of your
recovery codes, and tap **Sign In**.

## Adding more servers

You can add as many servers as you like, own.audio and Audiobookshelf mixed. Open
**Settings** (the gear on [Home](home.md)) and tap **Add a Server** under **Servers**. The
**Add Server** screen has the same fields and buttons as the first screen.

The library shows one server at a time: the selected one, with a checkmark in the list of
servers. To switch, use the server menu at the top left of Home, or tap **Use This Server** on
a server's page. A book that is playing keeps playing when you switch.

## The tabs

Once a server is added, the app has four tabs:

- **Home**: what you were listening to, and the server's shelves. See [Home](home.md).
- **Library**: every book, and ways in by series, author, narrator and collection. See
  [Library and search](library.md).
- **Downloads**: what is on this iPhone, from every server. See
  [Downloads and offline](downloads.md).
- **Search**: books, authors, narrators and series. See [Library and search](library.md#search).
