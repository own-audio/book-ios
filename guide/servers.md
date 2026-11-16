---
title: Servers
nav_order: 10
---

# Servers

Your servers are listed at the top of [Settings](settings.md), under **Servers**. Each row shows
the server's name, its kind (own.audio or Audiobookshelf) and your account. The selected server,
the one the library shows, has a checkmark. If a server refused your sign-in, the row says
**Sign-in refused · Sign in again** in red.

Swipe a server to **Remove** it, or tap it to open its page.

## A server's page

From the top:

- **Use This Server**: shown when it isn't the selected server. Makes it the one the library
  shows.
- **Check Now**: checks the connection and says **Connected**, **Sign-in refused** or
  **Unreachable**.
- **Account**: **Sign In Again** (see below). On own.audio also **Delete Account…**.
- **Family**, **Devices** and **Listening** (own.audio). See [Family](family.md).
- **Server**, **Address** (the address in use now) and **Name**. Tap **Name** to rename the
  server in the app.
- **Library** (Audiobookshelf): when your account has several book libraries, choose which one
  the app shows. Each is also in the server menu on Home.
- **Connection** and **Addresses** (below).
- **Library on This iPhone** (own.audio, below).
- **Remove Server**.

## Addresses

A server can have more than one address: one at home, one from outside, one through a VPN. The
app tries them and, on each network, uses the fastest one that answers, and only if it answers
as the same server.

- On **own.audio**, the server tells the app its other addresses.
- On **Audiobookshelf**, add them yourself.

Under **Addresses**, each address says where it came from: **Added with** (the address you
signed in with), **From the server** or **Added by you**. **Add Address** adds one, such as
`http://192.168.1.20:13378` or a Tailscale address. Swipe an address to remove it (except the
one you signed in with).

Under **Connection**, **Automatic** (the default) lets the app choose; pick an address to always
use that one.

## Library on This iPhone (own.audio)

The app keeps a list of everything on an own.audio server, without the audio, so the library
can be browsed offline. This section shows how many books and authors it holds and when it was
last updated. It is updated at launch, when the app comes to the foreground, and within seconds
of a change on the server while the app is open; iOS may also let the app update it in the
background. **Update Now** updates it at once.

## Sign In Again

When a server refuses the app's sign-in (for example after you changed your password), open
the server's page and tap **Sign In Again**. Type your password and tap **Sign In**; on
own.audio you can also use Apple or Google if the server offers them. Downloads and the library
on this iPhone stay as they are.

## Delete Account (own.audio)

**Delete Account…** deletes your account on that own.audio server for good, after asking,
with everything you added to it: music, audiobooks, podcasts, playlists and your listening
history. What others in your family added stays with them. Audiobookshelf accounts are made and
removed by the server's admin, so there is no such button for them.

## Removing a server

**Remove Server** (or a swipe in the list) removes the server from the app, after asking. Its
downloads leave this iPhone. Nothing changes on the server.
