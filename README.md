<div align="center">

<img src="Mezzanine/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="128" alt="Mezzanine">

# Mezzanine

**Reach the menu bar icons macOS is hiding.**

[![Download](https://img.shields.io/badge/download-1.0-blue)](../../releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Platform](https://img.shields.io/badge/macOS-26.0%2B-lightgrey)](#requirements)

</div>

---

When your menu bar runs out of room — the notch on a MacBook, or simply too many
icons — macOS drops the overflow silently. No indicator, no scroll, no way back.
The icons are still *there*: still running, still reporting positions, still
holding menus. They just aren't drawn.

Mezzanine puts a chevron at the right of your menu bar with a count of what's
missing. Click it and a slim bar opens directly beneath the menu bar showing
every hidden icon, each rendered with its **real glyph** — Docker's whale with
its update badge, a sync spinner mid-spin, whatever is actually on screen.
Click one and its genuine menu opens.

<!-- Screenshot goes here: the overflow bar open under a notched menu bar.
     Save it as docs/screenshot.png and swap in:
     ![Mezzanine](docs/screenshot.png) -->

## What makes it different

Most menu bar managers work by **moving your icons around** — hiding them behind
a divider you drag, or shuffling them in and out of a second row. That needs
your icons rearranged, and it needs the icon to be on screen before it can be
clicked.

Mezzanine moves nothing. It reads the menu bar through the Accessibility API,
works out which items macOS has declined to draw, and rebuilds each one's menu
as its own. Choosing an entry is forwarded straight back to the real menu item
in the owning app.

That distinction matters, because **a hidden status item cannot open its own
menu**. `AXPress` on one fails with `kAXErrorCannotComplete` — AppKit has no
on-screen anchor to hang the menu from. But the menu's *contents* stay fully
enumerable whether the item is drawn or not, and individual entries can be
pressed directly. Mirroring the menu is what turns an unreachable icon into a
usable one without touching your layout.

## Install

1. Download `Mezzanine-1.0.dmg` from the [latest release](../../releases/latest).
2. Drag Mezzanine to Applications and launch it.
3. Grant **Accessibility** when prompted.

The app is signed with a Developer ID and notarized by Apple, so it opens
without a Gatekeeper warning. To confirm you have an untampered build:

```sh
shasum -a 256 Mezzanine-1.0.dmg
spctl -a -vvv -t open --context context:primary-signature Mezzanine-1.0.dmg
xcrun stapler validate Mezzanine-1.0.dmg
```

The last two should report `accepted / Notarized Developer ID` and a valid
staple. [`RELEASES.md`](RELEASES.md) records the hash of every shipped build.

## Permissions, and why

Two prompts, one required and one not. Both look alarming without a reason next
to them, so here is the reason.

**Accessibility — required.** This is the whole mechanism. Reading which status
items exist, where they are, and what their menus contain is done entirely
through the Accessibility API, and there is no other way to see another app's
menu bar item. Without it Mezzanine can see nothing at all.

**Screen Recording — optional.** Used *only* to capture the small rectangle each
hidden icon occupies, so the bar can show its true glyph. The Accessibility API
exposes no images whatsoever — all 43 attributes on a status item and not one of
them is a picture — so a real glyph requires a screen capture. Decline it and
everything still works; the bar falls back to each item's application icon.
Capture runs only while the bar is open.

Mezzanine has no network code, no analytics, and no update check. Nothing it
reads leaves your Mac.

## Requirements

| | |
|---|---|
| macOS | 26.0 or later |
| Architecture | Universal (Apple silicon and Intel) |
| Sandbox | None — see below |

## How it works

Six small files, no dependencies:

| File | Responsibility |
|---|---|
| `MenuBarItemScanner.swift` | Enumerates every status item via `AXExtrasMenuBar` on each running app, and decides which ones macOS is actually drawing |
| `GlyphCapture.swift` | Captures each hidden item's real glyph with ScreenCaptureKit |
| `MirroredMenu.swift` | Rebuilds a hidden item's menu and forwards the chosen entry back to the real one |
| `OverflowPanel.swift` / `OverflowStripView.swift` | The bar itself — a borderless panel at menu level, 33pt tall, 5pt below the menu bar |
| `AppDelegate.swift` | Status item, hidden count badge, background scanning |

Two findings worth knowing if you're reading the code:

**Position tells you nothing.** macOS reports plausible coordinates for icons it
isn't drawing. On a notched display only the run that fits entirely inside
`auxiliaryTopRightArea` gets drawn; everything else is assigned coordinates
stretching left through the notch and quietly not rendered. Containment in the
drawable region is the only reliable test — and it has to be computed per
display, since a monitor placed left of the primary has negative x.

**Scanning is a performance problem.** A naïve full scan took **2143 ms**, of
which 1991 ms was asking the ~120 running processes that have no status items at
all, two of which never answer and burn the full messaging timeout each. It now
runs at roughly **20 ms** steady state, off the main thread, by skipping
`.prohibited` processes, dropping the timeout to 0.1 s, and caching which apps
came back empty with staggered re-checks.

[`NOTES.md`](NOTES.md) is the long version: every non-obvious thing this cost
time to work out, including the strict-concurrency fallout from moving the scan
off the main thread and the exact ordering notarizing a DMG demands.

## Building

```sh
git clone <this repo>
cd Mezzanine
open Mezzanine.xcodeproj
```

Or from the command line, with no signing required:

```sh
xcodebuild -scheme Mezzanine -configuration Release build CODE_SIGNING_ALLOWED=NO
```

The app icon is generated from code rather than drawn — `swift
scripts/make-icon.swift` renders every size in the asset catalog directly from
a vector description, so 16pt keeps its edges instead of being a blurry
downscale of 1024.

Producing a distributable build is one command:

```sh
scripts/release.sh                  # archive, sign, notarize, staple, package
scripts/release.sh --skip-notarize  # signed but not notarized, for checking the build
```

It verifies the certificate, the team ID, hardened runtime and the absence of
the sandbox *before* submitting anything to Apple, rather than learning about a
problem from a failed round trip. You'll need your own Developer ID; see
[`NOTES.md`](NOTES.md#releasing) for the full setup.

## Why not the Mac App Store

It isn't possible. Every App Store app must be sandboxed, and the sandbox
silently blocks reading other processes' accessibility trees. Verified with a
single app bundle signed both ways:

```
without sandbox:  12 apps' menu bar extras readable
with sandbox:      0
```

`AXIsProcessTrusted()` still returns `true` — the queries simply come back
empty, and no entitlement restores them. That's why every menu bar manager that
genuinely reaches other apps' items is a direct download.

## Limitations

- **No right-click on a bar icon.** Accessibility exposes only `AXPress` on a
  status item; there is no secondary-click action, and synthesizing one needs
  the real item to be on screen.
- **No update mechanism.** Direct-download apps don't get one for free. Watch
  the releases page, or open an issue if you'd like Sparkle wired up.
- **Untested on a display stacked above or below the primary.** The geometry
  goes through the same code path, but that arrangement was never available to
  try. Reports welcome.
- **Items without a menu** (those running a target/action instead) are pressed
  directly, which works while hidden — but if the press doesn't take, Mezzanine
  falls back to activating the owning app.

## Contributing

Issues and pull requests are welcome. If you're reporting a bug, macOS version
and monitor arrangement are the two things most likely to matter.

## License

MIT — see [LICENSE](LICENSE).
