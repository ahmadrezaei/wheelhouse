#!/bin/bash
# Builds, signs, notarizes and (optionally) publishes Wheelhouse for Mac (ARCHITECTURE-MAC sections 2.5 and 2.6).
#
#   scripts/release-mac.sh <version> <build> [options]
#
#   <version>        marketing version, for example 1.0.0
#   <build>          integer build number, higher than the last release
#
#   --no-publish     stop after the notarized, stapled DMG (steps 1 to 8); the DMG is left in <build dir>/releases. This is the
#                    build used for the owner check on a separate macOS user (section 13.2).
#   --no-notarize    stop after the signed DMG (no Apple credentials needed); implies --no-publish
#   --local          developer dry run: skips the clean-tree, main-branch, version-increase and gh checks and does not edit
#                    project.yml (the version and build number are passed to xcodebuild); implies --no-publish
#   --skip-tests     skip step 3 (run the suites yourself first)
#   -h, --help       this text
#
# Environment:
#   WH_NOTARY_PROFILE   notarytool keychain profile name (default: wheelhouse-notary). Created once by the owner:
#                         xcrun notarytool store-credentials wheelhouse-notary --key <AuthKey_XXXX.p8> --key-id <KEYID> --issuer <ISSUER-UUID>
#                       (or --apple-id/--team-id/--password with an app-specific password). This script never reads credentials.
#   WH_SIGN_IDENTITY    codesign identity (default: the Developer ID Application certificate of team JCZY58QP3L)
#   WH_EXPORT_PROFILE   name of a manual Developer ID provisioning profile for com.ahmadrezaei.wheelhouse.mac. When unset the export
#                       uses automatic signing with -allowProvisioningUpdates (Xcode's managed Developer ID profile)
#   WH_BUILD_DIR        build output directory (default: <repo>/.build/mac, which is git-ignored)
#
# DISTRIBUTION BUILDS HAVE THE DEVELOPMENT SAFETY GATE OFF (WHDevSafety = NO). Never launch the app this script produces on a macOS
# user that has a real ~/.kube or iCloud data; install it on the separate test user (section 13.2).
# The script never launches the app, never reads ~/.kube or .secrets/, and never pushes without step 10 and 11 being reached.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

TEAM=JCZY58QP3L
BUNDLE_ID=com.ahmadrezaei.wheelhouse.mac
IDENTITY="${WH_SIGN_IDENTITY:-Developer ID Application: Amirhossein Moussavinejad ($TEAM)}"
NOTARY_PROFILE="${WH_NOTARY_PROFILE:-wheelhouse-notary}"
BUILD="${WH_BUILD_DIR:-$REPO/.build/mac}"
REPO_SLUG=ahmadrezaei/wheelhouse
PAGES_BASE=https://ahmadrezaei.github.io/wheelhouse/mac

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

VERSION=""; BUILDNUM=""; PUBLISH=1; NOTARIZE=1; LOCAL=0; TESTS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-publish) PUBLISH=0 ;;
    --no-notarize) PUBLISH=0; NOTARIZE=0 ;;
    --local) LOCAL=1; PUBLISH=0 ;;
    --skip-tests) TESTS=0 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) if [ -z "$VERSION" ]; then VERSION="$1"; elif [ -z "$BUILDNUM" ]; then BUILDNUM="$1"; else echo "too many arguments" >&2; exit 2; fi ;;
  esac
  shift
done
[ -n "$VERSION" ] && [ -n "$BUILDNUM" ] || { usage >&2; exit 2; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.2.3" >&2; exit 2; }
[[ "$BUILDNUM" =~ ^[0-9]+$ ]] || { echo "error: build must be an integer" >&2; exit 2; }

step() { echo; echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

DD="$BUILD/derived"
ARCHIVE="$BUILD/Wheelhouse.xcarchive"
EXPORT="$BUILD/export"
RELEASES="$BUILD/releases"
APP="$EXPORT/Wheelhouse.app"
DMG="$RELEASES/Wheelhouse-$VERSION.dmg"
mkdir -p "$BUILD" "$RELEASES"

# ---------------------------------------------------------------------------------------------------------------------------- 1
step "1  preflight"
command -v xcodegen >/dev/null || die "xcodegen is not installed"
security find-identity -v -p codesigning | grep -qF "$IDENTITY" || die "signing identity not found in the keychain: $IDENTITY"
[ "$LOCAL" = 1 ] || {
  [ -z "$(git status --porcelain)" ] || die "the git tree is not clean"
  [ "$(git branch --show-current)" = main ] || die "releases are cut from main"
  last_tag="$(git tag --list 'mac-v*' | sed 's/^mac-v//' | sort -V | tail -1)"
  if [ -n "$last_tag" ]; then
    [ "$(printf '%s\n%s\n' "$last_tag" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] && [ "$last_tag" != "$VERSION" ] \
      || die "version $VERSION is not greater than the last release $last_tag"
  fi
  last_build="$(awk -F'"' '/MAC_BUILD_NUMBER:/ {print $2; exit}' project.yml)"
  # project.yml starts at 1.0.0 (build 1), so the first release (no mac-v tag yet) may reuse build 1.
  [ "$BUILDNUM" -gt "${last_build:-0}" ] || { [ -z "$last_tag" ] && [ "$BUILDNUM" -ge "${last_build:-0}" ]; } || die "build $BUILDNUM is not greater than the current build ${last_build:-0}"
  [ "$PUBLISH" = 0 ] || gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"
}
if [ "$NOTARIZE" = 1 ]; then
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || die "notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid (see the header of this script, or use --no-notarize)"
fi
# Sparkle tools come from the package artifacts that xcodebuild resolves into the derived data below.
xcodebuild -resolvePackageDependencies -project Wheelhouse.xcodeproj -scheme WheelhouseMac -derivedDataPath "$DD" >/dev/null
SPARKLE_BIN="$DD/SourcePackages/artifacts/sparkle/Sparkle/bin"
[ -x "$SPARKLE_BIN/generate_keys" ] || die "Sparkle tools not found in $SPARKLE_BIN"
"$SPARKLE_BIN/generate_keys" -p >/dev/null 2>&1 || die "the Sparkle EdDSA private key is not in the login keychain (generate_keys -p failed)"
pub_in_config="$(awk -F= '/^WH_SU_PUBLIC_ED_KEY/ {gsub(/[ \t]/, "", $0); sub(/^[^=]*=/, "", $0); print $0}' WheelhouseMac/Resources/Distribution.xcconfig)"
[ -n "$pub_in_config" ] || die "WH_SU_PUBLIC_ED_KEY is empty in Distribution.xcconfig"
[ "$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" = "$pub_in_config" ] || die "the keychain's Sparkle public key differs from Distribution.xcconfig"
scripts/fetch-helm.sh --verify-only

# ---------------------------------------------------------------------------------------------------------------------------- 2
step "2  version $VERSION (build $BUILDNUM)"
if [ "$LOCAL" = 0 ]; then
  sed -i '' -E "s/(MAC_MARKETING_VERSION: )\"[^\"]*\"/\1\"$VERSION\"/; s/(MAC_BUILD_NUMBER: )\"[^\"]*\"/\1\"$BUILDNUM\"/" project.yml
fi
xcodegen generate >/dev/null
VERS=(MAC_MARKETING_VERSION="$VERSION" MAC_BUILD_NUMBER="$BUILDNUM")

# ---------------------------------------------------------------------------------------------------------------------------- 3
if [ "$TESTS" = 1 ]; then
  step "3  lint and tests"
  scripts/lint-mac.sh
  swift test --package-path Packages/WheelhouseKit
  xcodebuild test -project Wheelhouse.xcodeproj -scheme WheelhouseMac -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD/test-derived"
else
  step "3  lint and tests (skipped)"
fi

# ---------------------------------------------------------------------------------------------------------------------------- 4
step "4  archive (Distribution configuration)"
rm -rf "$ARCHIVE" "$EXPORT"
# The archive is signed for development (automatic); the export step re-signs everything with Developer ID.
xcodebuild archive -project Wheelhouse.xcodeproj -scheme WheelhouseMac -configuration Distribution \
  -archivePath "$ARCHIVE" -derivedDataPath "$DD" -destination 'generic/platform=macOS' -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$TEAM" "${VERS[@]}" \
  | tail -3

# The app is not sandboxed, so Sparkle's XPC installer services are not needed (section 2.5): strip them before export re-signs.
ARCHAPP="$ARCHIVE/Products/Applications/Wheelhouse.app"
SPARKLE_FW="$ARCHAPP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE_FW"/Versions/*/XPCServices "$SPARKLE_FW/XPCServices"
[ -z "$(find "$ARCHAPP" -name '*.xpc')" ] || die "an XPC service is still embedded"

# ---------------------------------------------------------------------------------------------------------------------------- 5
step "5  export (Developer ID)"
OPTS="$REPO/scripts/ExportOptions-DeveloperID.plist"
if [ -n "${WH_EXPORT_PROFILE:-}" ]; then
  OPTS="$BUILD/ExportOptions-manual.plist"
  cp "$REPO/scripts/ExportOptions-DeveloperID.plist" "$OPTS"
  /usr/libexec/PlistBuddy -c "Set :signingStyle manual" "$OPTS"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles dict" "$OPTS"
  /usr/libexec/PlistBuddy -c "Add :provisioningProfiles:$BUNDLE_ID string $WH_EXPORT_PROFILE" "$OPTS"
fi
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" -exportPath "$EXPORT" -allowProvisioningUpdates | tail -3
[ -d "$APP" ] || die "export produced no Wheelhouse.app"

# ---------------------------------------------------------------------------------------------------------------------------- 6
step "6  hardened runtime on every Mach-O (helm, helpers, frameworks), then re-seal the app"
macho_files() { find "$APP" -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O" && printf "%s\n" "$1"' _ {} \; ; }
needs_fix=0
while IFS= read -r f; do
  info="$(codesign -dvv "$f" 2>&1 || true)"
  case "$info" in *"flags="*"(runtime"*) ;; *)
    echo "  signing $(basename "$f") with the runtime flag"
    codesign --force --options runtime --timestamp -s "$IDENTITY" "$f"; needs_fix=1 ;;
  esac
done < <(macho_files)
if [ "$needs_fix" = 1 ]; then
  # Entitlements and the embedded provisioning profile are kept; only the seal over the changed helper is renewed.
  codesign --force --options runtime --timestamp --preserve-metadata=entitlements,identifier,flags -s "$IDENTITY" "$APP"
fi

# ---------------------------------------------------------------------------------------------------------------------------- 7
step "7  verify signing, runtime, entitlements"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
while IFS= read -r f; do
  info="$(codesign -dvv "$f" 2>&1 || true)"
  case "$info" in *"flags="*"(runtime"*) ;; *) die "no hardened runtime: $f" ;; esac
  case "$info" in *"Timestamp="*) ;; *) die "no secure timestamp: $f" ;; esac
  case "$info" in *"Authority=Developer ID Application"*"($TEAM)"*) ;; *) die "not signed with Developer ID ($TEAM): $f" ;; esac
done < <(macho_files)
echo "every Mach-O has the hardened runtime, a secure timestamp and the Developer ID signature"
scripts/mac-entitlement-check.sh "$APP" --config Distribution
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" != "$VERSION" ] \
  || [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" != "$BUILDNUM" ]; then
  die "the built app does not carry version $VERSION ($BUILDNUM)"
fi
# Gatekeeper rejects an un-notarized Developer ID app ("Unnotarized Developer ID"); the real check runs after notarization (step 8).
spctl -a -t exec -vvv "$APP" 2>&1 | sed 's/^/  spctl (pre-notarization, informational): /' || true

# ---------------------------------------------------------------------------------------------------------------------------- 8
step "8  DMG"
STAGING="$BUILD/dmg-staging"
rm -rf "$STAGING" "$DMG"; mkdir -p "$STAGING"
ditto "$APP" "$STAGING/Wheelhouse.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Wheelhouse" -srcfolder "$STAGING" -format ULFO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
codesign --force --timestamp -s "$IDENTITY" "$DMG"
codesign --verify --verbose=2 "$DMG"
if [ "$NOTARIZE" = 0 ]; then
  echo; echo "signed DMG (NOT notarized): $DMG"; exit 0
fi
step "8  notarize and staple"
RESULT="$BUILD/notarytool-result.json"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$RESULT" || true
status="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$RESULT" 2>/dev/null || true)"
if [ "$status" != "Accepted" ]; then
  sid="$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$RESULT" 2>/dev/null || true)"
  [ -z "$sid" ] || xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" || true
  die "notarization did not succeed (status '${status:-unknown}'); see $RESULT"
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
spctl -a -t exec -vvv "$APP"
echo "notarized and stapled: $DMG"
if [ "$PUBLISH" = 0 ]; then
  echo; echo "stopped before publishing (--no-publish). Install this DMG on the separate macOS user, never on the owner's own account."
  exit 0
fi

# ---------------------------------------------------------------------------------------------------------------------------- 9
step "9  appcast"
NOTES="$REPO/docs/mac/notes/Wheelhouse-$VERSION.html"
[ -f "$NOTES" ] || die "release notes are missing: docs/mac/notes/Wheelhouse-$VERSION.html"
cp "$NOTES" "$RELEASES/Wheelhouse-$VERSION.html"
[ ! -f "$REPO/docs/mac/appcast.xml" ] || cp "$REPO/docs/mac/appcast.xml" "$RELEASES/appcast.xml"
"$SPARKLE_BIN/generate_appcast" "$RELEASES" \
  --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/mac-v$VERSION/" \
  --release-notes-url-prefix "$PAGES_BASE/notes/" \
  --link "$PAGES_BASE/" --maximum-versions 3

# ---------------------------------------------------------------------------------------------------------------------------- 10
step "10  GitHub release mac-v$VERSION"
ASSETS=("$DMG")
for d in "$RELEASES"/*.delta; do [ -e "$d" ] && ASSETS+=("$d"); done
NOTES_MD="$BUILD/notes.md"
printf 'Wheelhouse for Mac %s (build %s)\n\nRelease notes: %s/notes/Wheelhouse-%s.html\n' "$VERSION" "$BUILDNUM" "$PAGES_BASE" "$VERSION" > "$NOTES_MD"
gh release create "mac-v$VERSION" "${ASSETS[@]}" --title "Wheelhouse for Mac $VERSION" --notes-file "$NOTES_MD"

# ---------------------------------------------------------------------------------------------------------------------------- 11
step "11  commit the appcast and notes"
mkdir -p docs/mac/notes
cp "$RELEASES/appcast.xml" docs/mac/appcast.xml
git add docs/mac/appcast.xml "docs/mac/notes/Wheelhouse-$VERSION.html" project.yml
git commit -m "Release Wheelhouse for Mac $VERSION"
git push origin main

# ---------------------------------------------------------------------------------------------------------------------------- 12
step "12  manual smoke (not automated)"
cat <<EOF
On a separate macOS user account with no ~/.kube (or a clean VM user):
  1. download Wheelhouse-$VERSION.dmg from the release page, open it: Gatekeeper must not warn;
  2. Sparkle must offer the update from the previous version (including the delta);
  3. scripts/perf-sample.sh --scenario idle-1 against that build must pass (section 12.3.5).
EOF
