# Icon

`AppIcon.svg` is the source of the app icon: the own.audio construction — the five family
figures around the app's symbol, each in its own colour as in the own.audio mark
(`#FABB05`, `#29ABE2`, `#FF3B30`, `#FFCC00`, `#34C759`) — with a closed book in brown
(`#7A4A2B`, the app's accent; `#D7A97C` on the dark ground, where the darker brown would not
read). The same construction as own.audio Music's icon, the note swapped for the book. It is on
the light ground the other own.audio apps use; `AppIcon-dark.svg` is the dark-mode variant.
Render each at 1024 × 1024 with no rounded corners and no alpha; iOS rounds them. The welcome
screen shows the same artwork (`AppLogo` in the asset catalog, 360 px).

One icon only: no alternate icons.

```bash
node scripts/render-icons.mjs      # needs sharp; writes the PNGs into the asset catalog
```
