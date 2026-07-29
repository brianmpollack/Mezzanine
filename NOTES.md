# Mezzanine — working notes

Reaches the menu bar icons macOS hides when the bar overflows (the notch on a
MacBook, or just too many icons). Clicking the chevron opens a bar beneath the
menu bar showing every hidden icon with its real glyph; clicking one opens that
app's actual menu.

Most of what's below is stuff that cost real time to work out and isn't
documented anywhere obvious.

---

## How it works

**`MenuBarItemScanner`** — enumerates every status item on the bar through the
Accessibility API (`AXExtrasMenuBar` on each running app) and decides which ones
macOS is actually drawing.

**`GlyphCapture`** — captures each hidden item's real menu bar glyph with
ScreenCaptureKit. Optional; without Screen Recording permission the bar falls
back to app icons and everything else still works.

**`MirroredMenu`** — rebuilds a hidden item's menu as our own and forwards the
chosen entry back to the real menu item.

**`OverflowPanel` / `OverflowStripView`** — the bar itself. A borderless panel at
menu level, 33pt tall, 5pt below the menu bar, centered on our status item.

**`AppDelegate`** — status item, badge, background scanning.

Left-click opens the bar. Right-click gives version and Quit.

---

## Things that are true and non-obvious

**macOS reports positions for icons it isn't drawing.** An overflowed item keeps
a sensible-looking x coordinate — it just never appears. On a notched display
only the run that fits entirely inside `auxiliaryTopRightArea` is drawn;
everything else is assigned coordinates stretching left through the notch and
into the app-menu half of the bar, and silently not rendered. So position alone
tells you nothing. Containment in the drawable region is the test.

**A hidden item cannot open its own menu.** `AXPress` fails with
`kAXErrorCannotComplete` — AppKit has no on-screen anchor for the menu. Items
that run a target/action instead (Bitwarden, Claude) *do* work while hidden.

**But the menu's contents stay readable.** The `AXMenu` child and all its
`AXMenuItem`s are enumerable whether or not the item is drawn, and individual
menu items can be pressed directly. That's what `MirroredMenu` exploits, and
it's why the app needs no icon movement at all.

**Accessibility exposes no images.** All 43 attributes on a status item, and not
one is image-related. Real glyphs require screen capture.

**Hidden items still have live window backing stores.** ScreenCaptureKit will
capture them even though they're `onscr=false`. Matching an Accessibility item
to its window is exact on center-x — the window is a few points wider but shares
the item's center precisely.

**Bundled icon assets are not a substitute.** Docker ships 13 status item images
(6 animation frames, 6 sync frames, an update badge) and picking the right one
needs internal state we can't see. Bitwarden's is inside `app.asar`; Ollama
ships none. And the thing on screen is often composited at draw time — the whale
*with* its update badge exists nowhere as a file.

**Status item placement quirks:**
- Preferred position is a distance measured **leftward from the right end**, so 0
  is the rightmost slot. Writing a huge value parks you at the far left.
- Placement is decided **when the item is created**. An item created hidden lands
  at the far left and stays there even after `isVisible` is flipped.
- AppKit writes an item's real position back to its autosave key as it's removed,
  which races the value you write before recreating it.

**The sandbox blocks all of this**, silently — see App Store below.

---

## Multi-monitor

The menu bar follows whichever display you're working on, and a display placed
left of the primary has **negative** x coordinates. Geometry is computed per
screen for that reason; measuring against a single screen made the badge claim
every icon was hidden the moment a second monitor was in use.

Cocoa measures up from the bottom-left of the primary display, Accessibility
measures down from its top-left. `MenuBarGeometry` flips once at construction.

Untested: a display stacked **above or below** the primary. The vertical flip
goes through the same code path but that arrangement was never available to try.

---

## Performance

A full scan was **2143ms**, running every 2 seconds on the main thread. 121 of
132 running apps have no status items and accounted for 1991ms of it; two
processes never answer at all and burned the full 500ms messaging timeout each.

Now ~**20ms** steady state: skip `.prohibited` processes (verified no status
item owner is one), 0.1s timeout, cache apps that report no extras bar with
staggered re-checks, and run the whole thing off the main thread.

### The cost of moving it off the main thread

The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
everything is on the main actor unless it says otherwise. Moving the scan to a
background queue left `scanRaw` `nonisolated` while the state it reads stayed
main-actor isolated — ten warnings, and one of them real: the empty-app cache
was being mutated off the main thread with nothing guarding it.

It held together only because `AppDelegate` happened to funnel every scan
through one serial queue behind an `isScanning` flag. That contract lived in a
comment. The cache is now a `Mutex`, snapshotted at the top of a scan and
written back at the end so the lock is never held across the Accessibility
round trips.

`ScannedItem` needs an explicit `nonisolated` too. It's `@unchecked Sendable`
to cross queues, but under default main-actor isolation its memberwise
initializer belongs to the main actor, so the background scan couldn't build
one — the annotation and the isolation were saying opposite things.

Three more turned up once those were fixed, all from the same default-isolation
rule meeting an SDK that predates it:

- `MirroredMenuItem` is `nonisolated`, because `NSMenuItem`'s designated
  initializers are, and an override can't sit on a different actor from the
  declaration it overrides.
- `OverflowPanel` needs an `isolated deinit`. A plain `deinit` is nonisolated
  and so can't read the panel's own `dismissMonitor`, an opaque `Any?`.

  This is what sets `MACOSX_DEPLOYMENT_TARGET`: isolated deinit needs runtime
  support, so 26.0 is the floor. Everything else here is older — `Mutex` wants
  15.0 — so dropping below 26.0 means giving up the isolated `deinit`, which
  `hide()` already makes redundant since it removes the monitor itself.
- `kAXTrustedCheckOptionPrompt` is spelled out as a string literal. The header
  declares it `extern CFStringRef` with no `const`, so Swift imports it as a
  mutable global that strict concurrency won't read from an isolated context —
  and there's nowhere to move the reference to, because the reference *is* the
  violation.

The project builds at `SWIFT_VERSION = 5.0`, where all of the above are
warnings. It is currently clean under `SWIFT_VERSION=6.0` too, which is worth
re-checking after touching any of this:

    xcodebuild -scheme Mezzanine -configuration Release \
        build CODE_SIGNING_ALLOWED=NO SWIFT_VERSION=6.0

---

## Icon

Generated, not drawn: `swift scripts/make-icon.swift` renders every size in
`AppIcon.appiconset` straight from code. Each size is drawn from the vector
description rather than downscaled from 1024, so 16pt keeps its edges.

It needs to exist even though we're an `LSUIElement` app with no Dock tile —
without it the Screen Recording pane in System Settings lists us with a blank
placeholder, which looks like malware asking for your screen.

macOS caches that icon aggressively. After changing it, a rebuild alone may not
refresh the entry; `killall -9 SystemSettings` and reopening the pane does.

---

## App Store: not possible

Every Mac App Store app must be sandboxed, and the sandbox blocks reading other
processes' accessibility trees. Verified with one app bundle signed both ways:

```
without sandbox:  12 apps' menu bar extras readable
with sandbox:      0
```

`AXIsProcessTrusted()` still returns `true` — the queries just come back empty,
and no entitlement restores them.

Hidden Bar *is* on the App Store, sandboxed, requesting nothing but file read
access — because it only manipulates **its own** status items and makes you
Command-drag your icons into place. Bartender and Ice both need Accessibility
and are both direct downloads. That's the dividing line.

`LSUIElement` itself is fine on the App Store; the Dock icon was never the issue.

---

## Releasing

`scripts/release.sh` does the whole thing: archive, export with Developer ID,
verify, notarize, staple, and build a DMG. `--skip-notarize` stops before the
round trip to Apple, which is what you want when you're only checking the build
still signs.

```
scripts/release.sh                     # full release
scripts/release.sh --skip-notarize     # signed, not notarized
scripts/release.sh --staple-only [id]  # resume a run whose wait died
```

It refuses to start unless the credentials below are in place, and it checks the
things Apple would reject you for — hardened runtime, a secure timestamp, and
the absence of the sandbox — *before* submitting rather than after.

### Where the output goes

`build/` is scratch and is deleted at the start of every run. A full release
therefore ends by copying the DMG to **`dist/<version>/`**, which is the durable
copy — because the one artifact this script produces is the one thing it can
never produce again, and leaving it somewhere the next run deletes made keeping
it a matter of remembering to.

The version comes from `MARKETING_VERSION`, read out of the project rather than
typed, so the filename and the `dist/` path can't disagree with what's in the
bundle. It's cross-checked against the built `Info.plist` after export.

**An archived version is immutable.** If `dist/<version>/` already holds a DMG
the script refuses to start, in preflight, before spending a build and a round
trip to Apple. Overwriting it would destroy the only copy of something already
shipped, and no rebuild brings it back — bump the version, or move the directory
aside deliberately.

The run then prints a record to paste into `RELEASES.md`: hashes, both
submission ids, both signature timestamps. Assembled from the artifacts rather
than read back out of scrollback, which is how a wrong hash gets into the file
whose whole purpose is identifying exact bytes.

One wrinkle worth knowing if you touch that code: `codesign` prints timestamps
formatted for the current locale, and macOS separates the time from AM/PM with a
**narrow no-break space** (U+202F), not an ASCII one. `strptime` won't match it,
so the parse fails on a string that looks completely ordinary on screen. The
script swaps it out before parsing.

`dist/` stays gitignored. GitHub Releases is the archive of record; `dist/` is
the local staging copy and a convenience for re-verifying a build later.

### The account

Signing goes through an organization Apple Developer Program team, not the
personal one — which also has certificates on this machine and is not what this
app ships under. Getting that wrong is the most likely cause of a confusing
export failure.

The team ID lives in two **untracked** files, each with a tracked `.example`
alongside it, so the repo carries no account details:

| File | Used by |
|---|---|
| `scripts/ExportOptions.plist` | `release.sh`, for `-exportArchive` |
| `Signing.local.xcconfig` | the Xcode project, for `DEVELOPMENT_TEAM` |

Copy each `.example`, fill in the team, and neither Xcode nor `release.sh` asks
again. `release.sh` refuses to start if either is missing and prints the `cp` to
run.

**`Signing.xcconfig` is tracked and deliberately sets nothing.** It's the
project's base configuration and all it does is
`#include? "Signing.local.xcconfig"` — optional, note the `?`. That matters more
than it looks: a base configuration reference pointing at a file that isn't there
is a **hard build error**, not a warning, so wiring the untracked file in
directly means a fresh clone cannot build at all. The indirection is what lets
someone clone and build unsigned with no setup.

All three settings have to agree — Xcode signs the archive using the xcconfig
while `-exportArchive` uses `ExportOptions.plist`, and the certificate has to
belong to the same team. `release.sh` checks all of it in preflight: it resolves
`DEVELOPMENT_TEAM` through `-showBuildSettings` rather than grepping the file, so
what it validates is what Xcode will actually use. A mismatch fails with a
legible message instead of deep inside `xcodebuild`.

### One-time setup

**Developer ID Application certificate.** Different from the "Apple Development"
one used for local builds — that one only runs on the machine that made it.
Create it in Xcode ▸ Settings ▸ Accounts ▸ *your team* ▸ Manage Certificates… ▸
+ ▸ Developer ID Application. Only the team's Account Holder can.

If one already exists on another Mac, export the `.p12` from there instead of
making a second one. Apple caps how many you can hold, and revoking one
invalidates every build already signed with it.

The current certificate expires **1 Feb 2027**. Builds signed before then keep
working afterwards — that's what the secure timestamp is for — but you can't
sign anything new until it's renewed.

**Notarization credentials.** Notarytool needs an app-specific password, not
your Apple ID password. Make one at appleid.apple.com ▸ Sign-In and Security ▸
App-Specific Passwords, then store it in the keychain once:

```
xcrun notarytool store-credentials mezzanine-api \
    --apple-id "<the Apple ID on the team>" \
    --team-id "<your team ID>" \
    --password "xxxx-xxxx-xxxx-xxxx"
```

Preferred over a password is an App Store Connect API key, which belongs to the
team rather than a person and is revocable on its own — `release.sh` prints the
exact invocation if no credentials are found.

The profile is named **`mezzanine-api`**, which is what `release.sh` looks for;
`NOTARY_PROFILE` in the environment overrides it. Stored once, it persists — this
is not a per-release step.

**Not `notary`.** `store-credentials` reports success while leaving an older
item of the same name in place, and notarytool then keeps authenticating with
the stale one. The symptom is a 401 naming appleid.apple.com even though the key
is fine — and it's convincing, because it looks exactly like an expired
app-specific password. A stale `notary` profile is still on this machine and
still returns 401; `mezzanine-api` is the live one. If credentials ever look
dead, check the profile name before regenerating anything.

### What notarization actually is

Not review. An automated malware scan that returns a *ticket* saying Apple has
seen this exact binary. Without one, Gatekeeper on someone else's Mac refuses
the app no matter how correctly it's signed — which is exactly what
`--skip-notarize` leaves you with:

```
rejected
source=Unnotarized Developer ID
```

The script zips the app, submits it, and blocks on `--wait`. Usually a few
minutes.

Then it **staples** the ticket to the app. Stapling embeds the ticket in the
bundle so first launch works with no network. Unstapled, a user offline on first
run gets blocked.

A successful run ends with the Gatekeeper check flipping to `accepted`.

### The DMG is a second artifact, not a wrapper

A ticket is bound to the hash of the thing that was **submitted**. Submitting
the zipped app gets a ticket for the app and nothing else, so stapling the DMG
off the back of that submission fails — Apple has genuinely never seen the DMG:

```
CloudKit query for Mezzanine.dmg failed due to "Record not found"
```

The disk image needs its own trip through all three steps, and the order is
forced:

1. **Sign it.** `xcodebuild` signs the app, not the image wrapped around it. An
   unsigned DMG assesses as `rejected — no usable signature` however well
   notarized the app inside it is.
2. **Submit it**, as a separate submission from the app's.
3. **Staple it.**

Signing rewrites the DMG, so a ticket fetched before the signature no longer
matches its hash. Sign first or the staple is wasted.

Both artifacts end up stapled, and they're checked differently — the app as
`-t install`, the disk image as `-t open --context context:primary-signature`:

```
Mezzanine.app: accepted    source=Notarized Developer ID
Mezzanine.dmg: accepted    source=Notarized Developer ID
```

Worth testing the way a user meets it, since Gatekeeper only engages on
quarantined files — copy the DMG, `xattr -w com.apple.quarantine "0083;...;Safari;"`,
and assess that.

### When notarization fails

`--wait` prints the status. `Invalid` means the scan found something; get the
reasons with the submission ID it printed:

```
xcrun notarytool log <submission-id> --keychain-profile notary
xcrun notarytool history --keychain-profile notary
```

The usual causes are all things the preflight already checks, so a failure here
is more likely an unsigned nested binary than anything about this app — which
has no frameworks, no helpers, and nothing embedded.

### After a release

Changing the signing identity changes the app's identity as far as TCC is
concerned. Going from development-signed to Developer ID means every existing
Accessibility and Screen Recording grant stops applying, and the app has to be
removed and re-added in System Settings.

This only bites once. Notarizing doesn't alter the signature, so grants given to
a Developer ID build carry across to the notarized one and to every later
release.

Version numbers come from `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in
the project. The right-click menu shows the former.

---

## Next steps

**1. Notarized release — done.** Version 1.0 (build 2) is Developer ID signed,
notarized, stapled and packaged. Both artifacts pass Gatekeeper, including from a
quarantined copy:

```
Mezzanine.app: accepted    source=Notarized Developer ID
Mezzanine.dmg: accepted    source=Notarized Developer ID
```

Produced by `./scripts/release.sh` end to end from clean, which is the first time
the corrected DMG path has run without manual steps. `build/` is wiped at the
start of every run, so the shipped DMG lives in `dist/1.0/` and on the release
page; `RELEASES.md` carries its hashes.

Build 1 was an earlier 1.0, notarized on 28 July and never published — superseded
by the bundle identifier change, which makes it a different app to macOS. It's
kept under `dist/superseded/`.

**2. Open source — done.** MIT, public on GitHub, with the history squashed to a
single commit. `README.md` is the public face and states plainly why the app
asks for Accessibility and that Screen Recording is optional. The signing account
is not in the repo — see *The account* above.

Still outstanding:

- No update mechanism. Direct-download apps don't get one for free; Sparkle is
  the usual answer and needs an appcast and an EdDSA key.
- No screenshot in the README, which is the single thing most likely to matter
  for anyone deciding whether to download it.

**3. Optional, not started:**
- Show *all* icons in the bar rather than only hidden ones (Bartender does;
  roughly a one-line change to the filter in `AppDelegate.refresh`)
- Right-click on a bar icon. There's no Accessibility action for a secondary
  click — every item exposes only `AXPress` — so this needs the real item to be
  on screen. Currently unreachable.
- Badging the chevron when a hidden app's icon changes. Possible, but it needs
  continuous capture, which keeps the screen-recording indicator permanently lit.

---

## The abandoned approach: moving real items

Before the mirrored-menu design there was a `mover-wip` branch that moved *real*
status items with addressed `CGEvent`s. It isn't in the public history — it was
never shippable — but the findings are worth keeping.

The primitive works and is genuinely interesting: tagging an event
with `mouseEventWindowUnderMousePointer` / `eventTargetUnixProcessID` / field 51
and posting to the **session** tap (not the HID tap, which is what yanks the
cursor) moves another app's status item in ~65ms — including items macOS isn't
drawing, which a synthesized drag can't touch at all.

What doesn't work is composing many moves into a target arrangement. Individual
moves fail roughly half the time and successful ones often don't land where
asked, so convergence oscillates. Reading Ice afterwards showed why that was the
wrong goal: Ice moves its **own divider** — one move per toggle — and its
temp-show path moves a single item with a stored return destination. It never
reshuffles the bar. Anything built on this primitive should do the same.

Skipped pieces that likely matter if it's revived: Ice's full `scrombleEvent`
two-tap handshake, `wakeUpItem` before retries, and refusing to start while
modifiers are held or the mouse is moving.
