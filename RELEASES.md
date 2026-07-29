# Releases

What was actually shipped, and how to recognize it.

The binaries themselves aren't in git — see the note in `.gitignore`. They live
in `dist/` locally and on the release page. This file is the record that ties a
version to the exact bytes Apple notarized, which matters because a release can
never be rebuilt: signing stamps a fresh timestamp and notarization issues a
ticket for that binary alone, so a rebuild of identical source produces a
different artifact that these hashes will not match.

To check a DMG is one of ours:

```
shasum -a 256 Mezzanine-1.0.dmg
spctl -a -vvv -t open --context context:primary-signature Mezzanine-1.0.dmg
xcrun stapler validate Mezzanine-1.0.dmg
```

The last two should report `accepted / Notarized Developer ID` and a working
staple. They're the checks that matter — a matching hash only says the file is
unaltered, while those say Apple vouched for it.

---

## 1.0 — 29 July 2026

First public release. Developer ID signed, notarized and stapled. Verified from
a quarantined copy, which is the only state in which Gatekeeper actually
engages.

| | |
|---|---|
| Marketing version | 1.0 |
| Build | 2 |
| Minimum macOS | 26.0 |
| File | `Mezzanine-1.0.dmg` (1.7 MB) |

**Hashes**

```
DMG  sha256  cd0af4dd1703577732e05d4b95f72b7e7a5de642f15aa5d31455560c87c7aecd
DMG  cdhash  34ab20cf78020cd0e76bb54843b18974643f8e2d
app  cdhash  3bae828fe0dcd728edcc8396b9e0e94dfc0fd84d
```

**Notarization** — two submissions, because the app and the disk image are
separate artifacts:

```
7c2d0ebf-68bc-4947-9b86-91504fb1e520   Mezzanine.zip   Accepted   app
d54ca32b-dce4-4cc5-aaa7-9af41151384d   Mezzanine-1.0.dmg   Accepted   shipped
```

Signature timestamps: app `2026-07-29 18:39:57`, DMG `2026-07-29 18:40:25`.

**Notes.** Produced by `scripts/release.sh` end to end from clean — the first
release to go through the corrected DMG path without manual steps.

An earlier build 1 of 1.0 was notarized on 28 July and never published. It was
superseded before release by a change of bundle identifier — which makes it a
different app as far as macOS is concerned — and by a lower minimum macOS.
Build 2 is the first 1.0 anyone can have. The earlier artifact is kept locally
under `dist/superseded/`, since it can't be reproduced; the build number is what
distinguishes the two.
