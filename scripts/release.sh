#!/bin/bash
#
# Builds, signs, notarizes and packages Mezzanine for direct download.
#
# The Mac App Store isn't available to this app: every App Store app must be
# sandboxed, and the sandbox silently blocks reading other processes'
# accessibility trees — the same binary reads 12 apps' menu bar extras
# unsandboxed and 0 sandboxed. So distribution is Developer ID + notarization.
#
# Usage:
#   scripts/release.sh                     build, sign, notarize, package
#   scripts/release.sh --skip-notarize     stop before the round trip to Apple
#   scripts/release.sh --staple-only [id]  finish a run whose upload survived
#                                          but whose wait didn't
#
# The scan happens on Apple's side and keeps going whatever happens to this
# process, so losing the connection while waiting doesn't lose the submission —
# only the handle on it. The id is written to build/submission-id the moment
# it's issued, and --staple-only picks it up from there.
#
# A full run ends by copying the DMG into dist/<version>/ and printing a record
# to paste into RELEASES.md. Everything in build/ is scratch and is deleted at
# the start of the next run; dist/ is the durable copy, and the script refuses
# to overwrite a version already archived there.
#
set -euo pipefail

cd "$(dirname "$0")/.."

SCHEME="Mezzanine"
PROJECT="Mezzanine.xcodeproj"
APP_NAME="Mezzanine"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/$APP_NAME.app"
SUBMISSION_FILE="$BUILD_DIR/submission-id"
# Not "notary": store-credentials will happily report success while leaving an
# older item of the same name in place, and notarytool then keeps authenticating
# with the stale one. Symptom is a 401 naming appleid.apple.com even though the
# key is valid — which it will be, if you test it with --key directly. A fresh
# profile name sidesteps the whole problem.
NOTARY_PROFILE="${NOTARY_PROFILE:-mezzanine-api}"
EXPORT_OPTIONS="scripts/ExportOptions.plist"
SIGNING_CONFIG="Signing.local.xcconfig"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

SKIP_NOTARIZE=false
STAPLE_ONLY=false
SUBMISSION_ID=""

case "${1:-}" in
    "")               ;;
    --skip-notarize)  SKIP_NOTARIZE=true ;;
    --staple-only)    STAPLE_ONLY=true; SUBMISSION_ID="${2:-}" ;;
    *)                fail "unknown option: $1" ;;
esac

# Neither file is in the repo — they hold the signing account, and each has a
# tracked .example alongside it. Checked before anything else so a fresh clone
# gets told what to do rather than a PlistBuddy error.
if [[ ! -f "$EXPORT_OPTIONS" ]]; then
    fail "$EXPORT_OPTIONS is missing.

  cp $EXPORT_OPTIONS.example $EXPORT_OPTIONS

then put your Apple Developer Program team ID in it."
fi
if [[ ! -f "$SIGNING_CONFIG" ]]; then
    fail "$SIGNING_CONFIG is missing.

  cp $SIGNING_CONFIG.example $SIGNING_CONFIG

then put the same team ID in it. (Unsigned builds don't need either file —
add CODE_SIGNING_ALLOWED=NO to a plain xcodebuild invocation.)"
fi

TEAM_ID="$(/usr/libexec/PlistBuddy -c 'Print :teamID' "$EXPORT_OPTIONS")"

# One call, two settings. Authoritative in a way that grepping the files is not:
# it resolves the optional include in Signing.xcconfig, so this is the team Xcode
# will actually build with. Read before anything is built, because the archive
# guard in preflight has to fire before a round trip to Apple rather than after.
BUILD_SETTINGS="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -configuration Release -showBuildSettings 2>/dev/null)"
VERSION="$(awk '$1 == "MARKETING_VERSION" { print $3; exit }' <<<"$BUILD_SETTINGS")"
XCODE_TEAM="$(awk '$1 == "DEVELOPMENT_TEAM" { print $3; exit }' <<<"$BUILD_SETTINGS")"
[[ -n "$VERSION" ]] || fail "couldn't read MARKETING_VERSION from $PROJECT"

DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DIST_DIR="dist/$VERSION"

# ---------------------------------------------------------------- preflight

step "Checking prerequisites"

# Two files hold the team and they must agree. Xcode signs the app using the
# xcconfig; -exportArchive uses ExportOptions.plist. A mismatch means the export
# tries to re-sign for a team the archive wasn't built for, which surfaces much
# later as an opaque xcodebuild failure.
if [[ -z "$XCODE_TEAM" ]]; then
    fail "no DEVELOPMENT_TEAM resolved from $SIGNING_CONFIG — is the team ID filled in?"
fi
if [[ "$XCODE_TEAM" != "$TEAM_ID" ]]; then
    fail "team mismatch: $SIGNING_CONFIG says $XCODE_TEAM, $EXPORT_OPTIONS says $TEAM_ID"
fi
echo "  ✓ team $TEAM_ID (both config files agree)"

# Command output is captured before being matched, never piped into `grep -q`.
# Under `pipefail` a `grep -q` that matches exits while the writer is still
# going, the writer takes SIGPIPE, and the pipeline reports 141 — so the check
# fails exactly when it should pass. Whether it bites depends on how much
# output fits in the pipe buffer, which makes it flaky rather than obvious.
IDENTITIES="$(security find-identity -v -p codesigning)"
DEVELOPER_ID_CERTS="$(grep "Developer ID Application" <<<"$IDENTITIES" || true)"

if [[ -z "$DEVELOPER_ID_CERTS" ]]; then
    cat >&2 <<'EOS'
No "Developer ID Application" certificate found.

That certificate is what lets other people run the app without Gatekeeper
blocking it, and it's separate from the "Apple Development" one used for local
builds. It needs a paid Apple Developer Program membership.

To create it:
  Xcode ▸ Settings ▸ Accounts ▸ (your team) ▸ Manage Certificates…
  ▸ + ▸ Developer ID Application

Then re-run this script.
EOS
    exit 1
fi
echo "  ✓ Developer ID Application certificate"

# The certificate carries its team in parentheses. A mismatch here means the
# team was never updated after the signing account changed, and the export
# would otherwise fail much later with a far less obvious message.
if ! grep -q "($TEAM_ID)" <<<"$DEVELOPER_ID_CERTS"; then
    cat >&2 <<EOS
The Developer ID certificate isn't for team $TEAM_ID.

Certificates found:
$DEVELOPER_ID_CERTS

Put the right team ID in scripts/ExportOptions.plist and in DEVELOPMENT_TEAM
in the Xcode project, then re-run.
EOS
    exit 1
fi
echo "  ✓ certificate matches team $TEAM_ID"

# The DMG is signed by hand further down (xcodebuild only signs the app), so the
# identity has to be pinned to the same team rather than left to codesign's
# guess — this machine also carries certificates for the personal team.
SIGN_IDENTITY="$(grep "($TEAM_ID)" <<<"$DEVELOPER_ID_CERTS" \
    | head -1 | sed 's/.*"\(.*\)".*/\1/')"
[[ -n "$SIGN_IDENTITY" ]] || fail "couldn't parse a signing identity for team $TEAM_ID"

if [[ "$SKIP_NOTARIZE" == false ]]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat >&2 <<EOS
No notarization credentials stored under the profile "$NOTARY_PROFILE".

Preferred: an App Store Connect API key (Users and Access ▸ Integrations ▸
Keys, Team Keys tab, Developer role or above). It belongs to the team rather
than to a person, and is revocable without touching anything else.

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --key ~/.appstoreconnect/private_keys/AuthKey_XXXXXXXXXX.p8 \\
      --key-id XXXXXXXXXX \\
      --issuer <issuer-uuid>

Or an app-specific password from https://appleid.apple.com. Omit --password
to be prompted, rather than putting the secret in your shell history:

  xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
      --apple-id "<the Apple ID on team $TEAM_ID>" --team-id "$TEAM_ID"

Or run with --skip-notarize to produce an unsigned-for-distribution build.
EOS
        exit 1
    fi
    echo "  ✓ notarization credentials ($NOTARY_PROFILE)"

    # A notarized artifact can never be reproduced: signing stamps a fresh
    # timestamp and Apple issues a ticket for those exact bytes. So an archived
    # release is treated as immutable — silently overwriting one would destroy
    # the only copy of something already shipped, and no rebuild can bring it
    # back. Refuse early, before spending a build and a round trip to Apple.
    if [[ -e "$DIST_DIR/$APP_NAME-$VERSION.dmg" ]]; then
        fail "$DIST_DIR/$APP_NAME-$VERSION.dmg already exists — $VERSION has shipped.

Bump MARKETING_VERSION in $PROJECT, or move that directory aside by hand if
you're deliberately replacing a build that was never released."
    fi
    echo "  ✓ $DIST_DIR is clear"
fi

# ------------------------------------------------------------------- build

# --staple-only resumes an earlier run, so it keeps that run's app rather than
# rebuilding: a rebuild would produce a different binary from the one Apple
# scanned, and its ticket wouldn't apply.
if [[ "$STAPLE_ONLY" == true ]]; then
    [[ -d "$APP" ]] || fail "no app at $APP — --staple-only resumes a run, it can't start one"

    if [[ -z "$SUBMISSION_ID" ]]; then
        [[ -f "$SUBMISSION_FILE" ]] \
            || fail "no submission id given and none saved at $SUBMISSION_FILE"
        SUBMISSION_ID="$(<"$SUBMISSION_FILE")"
    fi
    step "Resuming submission $SUBMISSION_ID"
else
    step "Archiving Release build"
    rm -rf "$BUILD_DIR"
    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$ARCHIVE" \
        -destination 'generic/platform=macOS' \
        CODE_SIGN_STYLE=Automatic \
        | grep -E "error:|warning:|ARCHIVE" || true

    [[ -d "$ARCHIVE" ]] || fail "archive failed"

    step "Exporting with Developer ID"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE" \
        -exportPath "$EXPORT_DIR" \
        -exportOptionsPlist scripts/ExportOptions.plist \
        | grep -E "error:|Exported" || true

    [[ -d "$APP" ]] || fail "export failed — no app at $APP"

    # -showBuildSettings resolves the version independently of the build itself,
    # so confirm the two agree rather than trusting a filename that claims a
    # version the bundle doesn't carry.
    BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP/Contents/Info.plist" 2>/dev/null || true)"
    [[ "$BUILT_VERSION" == "$VERSION" ]] || fail \
        "version mismatch: project says $VERSION, bundle says ${BUILT_VERSION:-nothing}"
    echo "  ✓ version $VERSION"
fi

# ------------------------------------------------------------------ verify

step "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'

SIGNATURE="$(codesign -d --verbose=2 "$APP" 2>&1)"

# Hardened runtime is mandatory for notarization; catch it here rather than
# after a round trip to Apple.
if ! grep -q "flags=.*runtime" <<<"$SIGNATURE"; then
    fail "hardened runtime is not enabled (ENABLE_HARDENED_RUNTIME must be YES)"
fi
echo "  ✓ hardened runtime enabled"

# Without a secure timestamp the app stops validating the day the certificate
# expires, instead of staying good for the builds already in people's hands.
if ! grep -q "^Timestamp=" <<<"$SIGNATURE"; then
    fail "signature has no secure timestamp"
fi
echo "  ✓ secure timestamp"

# The sandbox must stay off or the app silently reads nothing.
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if grep -q "app-sandbox" <<<"$ENTITLEMENTS"; then
    fail "app is sandboxed — Accessibility reads will return nothing"
fi
echo "  ✓ not sandboxed"

# --------------------------------------------------------------- notarize

if [[ "$SKIP_NOTARIZE" == false ]]; then

    if [[ "$STAPLE_ONLY" == false ]]; then
        step "Uploading to Apple"
        ZIP="$BUILD_DIR/$APP_NAME.zip"
        ditto -c -k --keepParent "$APP" "$ZIP"

        # Upload and wait are separate calls so the id can be written down in
        # between. `submit --wait` only prints it to stdout, so a run that died
        # mid-wait used to take the only handle on a finished scan with it.
        SUBMIT_OUTPUT="$(xcrun notarytool submit "$ZIP" \
            --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
            || { sed 's/^/  /' <<<"$SUBMIT_OUTPUT"; fail "upload failed"; }
        sed 's/^/  /' <<<"$SUBMIT_OUTPUT"

        SUBMISSION_ID="$(grep -m1 -E '^[[:space:]]*id:' <<<"$SUBMIT_OUTPUT" \
            | awk '{print $2}')"
        [[ -n "$SUBMISSION_ID" ]] || fail "no submission id in notarytool output"

        echo "$SUBMISSION_ID" > "$SUBMISSION_FILE"
        echo "  ✓ id saved to $SUBMISSION_FILE"

        step "Waiting for Apple's verdict (usually a few minutes)"
        if ! xcrun notarytool wait "$SUBMISSION_ID" \
                --keychain-profile "$NOTARY_PROFILE"; then
            cat >&2 <<EOS

Lost contact with Apple while waiting. The scan itself is unaffected — it runs
on their side and finishes whether or not anything is listening.

Resume once, without rebuilding or resubmitting:

  scripts/release.sh --staple-only $SUBMISSION_ID
EOS
            exit 1
        fi
    fi

    # Reached either way: a fresh run has just been told the verdict, a resumed
    # one has yet to ask.
    step "Checking the verdict"
    INFO="$(xcrun notarytool info "$SUBMISSION_ID" \
        --keychain-profile "$NOTARY_PROFILE" 2>&1)" \
        || { sed 's/^/  /' <<<"$INFO"; fail "couldn't read submission $SUBMISSION_ID"; }
    sed 's/^/  /' <<<"$INFO"

    STATUS="$(grep -m1 -E '^[[:space:]]*status:' <<<"$INFO" | sed 's/.*status: //')"
    if [[ "$STATUS" != "Accepted" ]]; then
        cat >&2 <<EOS

Apple returned "$STATUS", not Accepted. The reasons:

  xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE
EOS
        exit 1
    fi
    echo "  ✓ accepted"

    step "Stapling ticket"
    # Resolved from the app's own signature, so this needs neither the
    # submission id nor the connection the wait was using.
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP" | sed 's/^/  /'
fi

# ----------------------------------------------------------------- package

step "Building DMG"
DMG_ROOT="$BUILD_DIR/dmg"
rm -rf "$DMG_ROOT" "$DMG"
mkdir -p "$DMG_ROOT"
cp -R "$APP" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"

hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_ROOT" \
    -ov -format UDZO "$DMG" | sed 's/^/  /'

if [[ "$SKIP_NOTARIZE" == false ]]; then
    # The disk image needs its own trip through all three steps. A ticket is
    # bound to the hash of the artifact that was *submitted*, and the only thing
    # submitted so far is the zipped app — so stapling the DMG off the back of
    # that submission fails with "Record not found". The DMG is a separate
    # artifact and Apple has never seen it.
    #
    # Order matters: signing rewrites the DMG, so a ticket obtained before the
    # signature would no longer match. Sign, then submit, then staple.
    step "Signing DMG"
    # Without a signature of its own the disk image assesses as "no usable
    # signature" however well notarized the app inside it is.
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    echo "  ✓ signed as $SIGN_IDENTITY"

    step "Notarizing DMG"
    DMG_OUTPUT="$(xcrun notarytool submit "$DMG" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)" \
        || { sed 's/^/  /' <<<"$DMG_OUTPUT"; fail "DMG notarization failed"; }
    sed 's/^/  /' <<<"$DMG_OUTPUT"

    DMG_STATUS="$(grep -E '^[[:space:]]*status:' <<<"$DMG_OUTPUT" \
        | tail -1 | sed 's/.*status: //')"
    [[ "$DMG_STATUS" == "Accepted" ]] || fail "Apple returned \"$DMG_STATUS\" for the DMG"

    # Kept for the record below. The app and the DMG are separate submissions,
    # so RELEASES.md has to name both to be a complete account of a release.
    DMG_SUBMISSION_ID="$(grep -m1 -E '^[[:space:]]*id:' <<<"$DMG_OUTPUT" \
        | awk '{print $2}')"

    step "Stapling DMG"
    xcrun stapler staple "$DMG" | sed 's/^/  /'
fi

# ------------------------------------------------------------------ report

step "Final Gatekeeper check"
GATEKEEPER="$(spctl -a -vvv -t install "$APP" 2>&1 || true)"
sed 's/^/  /' <<<"$GATEKEEPER"
if grep -q "accepted" <<<"$GATEKEEPER"; then
    echo "  ✓ Gatekeeper accepts this build"
else
    echo "  (not accepted — expected if you used --skip-notarize)"
fi

# The DMG is what people actually download, so assess it too — and as a disk
# image, which is a different assessment type from the app inside it.
if [[ "$SKIP_NOTARIZE" == false ]]; then
    DMG_GATEKEEPER="$(spctl -a -vvv -t open \
        --context context:primary-signature "$DMG" 2>&1 || true)"
    sed 's/^/  /' <<<"$DMG_GATEKEEPER"
    if grep -q "accepted" <<<"$DMG_GATEKEEPER"; then
        echo "  ✓ Gatekeeper accepts the DMG"
    else
        fail "the DMG does not pass Gatekeeper — do not ship it"
    fi
fi

# ------------------------------------------------------------------ archive

if [[ "$SKIP_NOTARIZE" == false ]]; then
    # build/ is wiped at the start of every run, so the one output of this script
    # that can never be rebuilt does not get left there depending on someone
    # remembering to copy it out. Unnotarized builds are deliberately not
    # archived: they aren't releases and nothing should be able to mistake one
    # for a release later.
    step "Archiving to $DIST_DIR"
    mkdir -p "$DIST_DIR"
    cp "$DMG" "$DIST_DIR/"
    echo "  ✓ $DIST_DIR/$(basename "$DMG")"

    # Assembled here rather than read back out of scrollback afterwards, which is
    # how a wrong hash gets into the record whose entire purpose is identifying
    # these exact bytes.
    step "Record for RELEASES.md"
    APP_SIG="$(codesign -dvvv "$APP" 2>&1)"
    DMG_SIG="$(codesign -dvvv "$DMG" 2>&1)"
    PLIST="$APP/Contents/Info.plist"

    # Actual byte length, not `du`, which reports allocated disk blocks — those
    # depend on the filesystem and on whether the copy was an APFS clone, and
    # reported 2.7 MB for a 1.8 MB image. The record is about the file, not the
    # volume it happens to be sitting on.
    dmg_size() {
        awk -v b="$(stat -f %z "$DMG")" 'BEGIN {
            if (b >= 1048576) printf "%.1f MB", b / 1048576
            else              printf "%.0f KB", b / 1024
        }'
    }

    # codesign prints timestamps locale-formatted ("Jul 27, 2026 at 3:07:42 PM").
    # RELEASES.md is a record meant to be compared across versions, so normalize
    # to something sortable — falling back to the raw string rather than losing
    # the timestamp if the locale doesn't parse.
    iso_timestamp() {
        local raw
        raw="$(awk -F= '/^Timestamp=/ { print $2 }' <<<"$1")"
        # codesign formats for the current locale, and macOS separates the time
        # from AM/PM with a narrow no-break space (U+202F) rather than a plain
        # one — which strptime will not match, so the parse fails on a string
        # that looks perfectly ordinary on screen. Swap it and its non-breaking
        # cousin (U+00A0) for ASCII spaces first.
        raw="${raw//$'\xe2\x80\xaf'/ }"
        raw="${raw//$'\xc2\xa0'/ }"
        LC_ALL=C date -j -f '%b %d, %Y at %I:%M:%S %p' "$raw" \
            '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf '%s' "$raw"
    }
    cat <<EOS

## $VERSION — $(date '+%d %B %Y' | sed 's/^0//')

| | |
|---|---|
| Marketing version | $VERSION |
| Build | $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") |
| Minimum macOS | $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PLIST" 2>/dev/null || echo 'see MACOSX_DEPLOYMENT_TARGET') |
| File | \`$(basename "$DMG")\` ($(dmg_size)) |

**Hashes**

\`\`\`
DMG  sha256  $(shasum -a 256 "$DMG" | awk '{print $1}')
DMG  cdhash  $(awk -F= '/^CDHash=/ { print $2 }' <<<"$DMG_SIG")
app  cdhash  $(awk -F= '/^CDHash=/ { print $2 }' <<<"$APP_SIG")
\`\`\`

**Notarization** — two submissions, because the app and the disk image are
separate artifacts:

\`\`\`
$SUBMISSION_ID   $APP_NAME.zip   Accepted   app
${DMG_SUBMISSION_ID:-unknown}   $(basename "$DMG")   Accepted   shipped
\`\`\`

Signature timestamps: app \`$(iso_timestamp "$APP_SIG")\`, DMG \`$(iso_timestamp "$DMG_SIG")\`.
EOS
fi

step "Done"
echo "  App: $APP"
echo "  DMG: $DMG"
if [[ "$SKIP_NOTARIZE" == false ]]; then
    echo "  Archived: $DIST_DIR/$(basename "$DMG")"
    echo
    echo "  Next: paste the record above into RELEASES.md, then attach the"
    echo "  archived DMG to a GitHub release on tag v$VERSION."
fi
echo
echo "  On first launch users are asked for Accessibility, which the app needs"
echo "  to see menu bar items at all. Screen Recording is optional and only"
echo "  affects whether icons show real glyphs or app icons."
