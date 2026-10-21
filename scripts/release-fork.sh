#!/usr/bin/env bash
# Builds, signs and publishes Coucou for macOS on the fork's GitHub releases, where the
# in-app updater (MacUpdate.swift) finds it. Self-signed with "Coucou Local Signing": no
# Apple Developer ID, no notarization, no iPhone link.
#
#   ./scripts/release-fork.sh            build, sign, tag v<version>-rc.<n>, publish
#
# <version> is upstream's, from NotchBuddy/project.yml; rc.<n> counts the fork's builds of
# it, back to rc.1 after each upstream bump. The release notes are the commits since the
# previous rc tag. Run it from a clean checkout of dev.
set -euo pipefail

REPO="FalconiZzare/coucou"
IDENTITY="Coucou Local Signing"
BUNDLE_ID="fr.louisraille.NotchBuddy"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATER="$REPO_ROOT/NotchBuddy/Sources/App/MacUpdate.swift"

die() { echo "error: $*" >&2; exit 1; }

cd "$REPO_ROOT"
command -v gh >/dev/null || die "gh is not installed (brew install gh)"

# The release must match a commit: no uncommitted changes to tracked files.
if ! git diff --quiet || ! git diff --cached --quiet; then
  die "commit or stash your changes first, the release has to match a commit"
fi
COMMIT=$(git rev-parse HEAD)

# ── 1. The signing key, and the one the updater pins ──────────────────────────
# "|| true": with pipefail, grep finding nothing would end the script silently.
SHA1=$(security find-identity -v -p codesigning | grep -F "\"$IDENTITY\"" | head -1 | awk '{print $2}' || true)
[ -n "$SHA1" ] || die "no '$IDENTITY' identity in the keychain: import your .p12 backup of it"
grep -q "certificateSHA1 = \"$SHA1\"" "$UPDATER" \
  || die "MacUpdate.swift pins another certificate than '$IDENTITY' ($SHA1): installed apps would refuse this build"
grep -q "owner = \"${REPO%%/*}\"" "$UPDATER" \
  || die "MacUpdate.swift looks for updates on another repo than $REPO"

# ── 2. Version: upstream's, then the next rc ──────────────────────────────────
cd "$REPO_ROOT/NotchBuddy"
xcodegen generate >/dev/null
BASE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
git fetch -q origin --tags
LAST=$(git tag -l "v$BASE-rc.*" | sed -n "s/^v$BASE-rc\.\([0-9][0-9]*\)$/\1/p" | sort -n | tail -1)
VERSION="$BASE-rc.$(( ${LAST:-0} + 1 ))"
TAG="v$VERSION"
BUILD_DIR="/tmp/coucou-fork-release-$VERSION"
APP="$BUILD_DIR/Coucou.app"
ZIP="$BUILD_DIR/Coucou.zip"
echo "Releasing $TAG"

# ── 3. Build, stamp the version, sign ─────────────────────────────────────────
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
xcodebuild \
  -project NotchBuddy.xcodeproj \
  -scheme NotchBuddy \
  -configuration ReleaseFork \
  -quiet \
  build \
  CONFIGURATION_BUILD_DIR="$BUILD_DIR"

# The signature seals Info.plist, so the version goes in first.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/Coucou.entitlements --sign "$SHA1" "$APP"

# What the updater checks on the users' Macs before it replaces anything.
codesign --verify --strict --deep -R="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$SHA1\"" "$APP" \
  || die "the signed app does not pass the updater's check"
cd "$REPO_ROOT"

ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release zip ready: $ZIP"

# ── 4. Notes: the commits since the previous rc (since main for the first one) ─
PREV=$(git tag -l "v*-rc.*" --sort=-v:refname | head -1)
CHANGES=$(git log --no-merges --format='- %s' "${PREV:-origin/main}..$COMMIT" | head -40)
[ -n "$CHANGES" ] || CHANGES="- Rebuilt on Coucou $BASE"

NOTES="Coucou $VERSION for macOS 15 or later (Apple silicon and Intel): upstream Coucou $BASE with the fork's changes.

## What's new

$CHANGES

## Install (once)

1. Download Coucou.zip below and unzip it.
2. Move Coucou.app to your Applications folder, replacing the old one if you have it.
3. Open it. macOS can't check who made it (it is signed, but not by Apple): open System Settings → Privacy & Security, click Open Anyway, then Open.
   Or, in Terminal: \`xattr -dr com.apple.quarantine /Applications/Coucou.app\`
4. Say yes when Coucou asks to look for new versions: the next ones install from the notch."

echo
echo "──────── Release notes ────────"
echo "$NOTES"
echo "───────────────────────────────"
echo
read -r -p "Tag $(git rev-parse --short "$COMMIT") as $TAG and publish it on $REPO? [y/N] " ANSWER
case "$ANSWER" in
  y|Y|yes) ;;
  *) die "stopped before tagging, nothing was published" ;;
esac

# ── 5. Tag the built commit + GitHub release ──────────────────────────────────
git tag "$TAG" "$COMMIT"
git push origin "$TAG"

gh release create "$TAG" "$ZIP" \
  --repo "$REPO" \
  --title "Coucou $VERSION" \
  --latest \
  --notes "$NOTES"

echo "✓ $TAG released: https://github.com/$REPO/releases/tag/$TAG"
