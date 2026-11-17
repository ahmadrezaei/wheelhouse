#!/bin/bash
# Archives, checks and uploads the Mac App Store edition of Wheelhouse to App Store Connect (design/mac/MAS-EDITION.md section 4).
#
#   scripts/release-mac-appstore.sh <version> <build> [--no-upload] [--skip-tests]
#
#   <version>        marketing version, for example 1.0.0
#   <build>          integer build number, higher than the last mas-v* tag's
#
#   (default)        preflight, lint and tests, archive, entitlement check, export and UPLOAD to App Store Connect, then tag
#                    mas-v<version>-<build> locally. UPLOADING IS THE DEFAULT but asks you to type the version first; --no-upload stops short of it.
#   --no-upload      stop after the export to <build dir>/export (destination export) and the check of the exported package's app;
#                    nothing is uploaded and no tag is created. Never open that .pkg on your own macOS user
#   --skip-tests     skip the lint and test step (run the suites yourself first)
#   -h, --help       this text
#
# Environment:
#   WH_MAS_BUILD_DIR   build output directory (default: <repo>/.build/mas, which is git-ignored)
#
# Signing and upload use the Apple account that Xcode is signed in to (Settings > Accounts), with automatic signing and
# -allowProvisioningUpdates, the same way the iOS build was uploaded. This script never reads .secrets/, ~/.kube or any API key.
# It never pushes, and it never launches the app it builds.
#
# The versions reach xcodebuild on the command line (MAS_MARKETING_VERSION, MAS_BUILD_NUMBER); project.yml is not edited, so the
# tree stays clean.
#
# A DISTRIBUTION BUILD HAS THE DEVELOPMENT SAFETY GATE OFF (WHDevSafety = NO) and carries the shared iCloud keychain group, which
# may hold PRODUCTION clusters. Never launch it on a macOS user that has a real ~/.kube or iCloud data: use the separate test
# user (design/mac/RELEASE-CHECKLIST-MAS.md).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

TEAM=JCZY58QP3L
BUILD="${WH_MAS_BUILD_DIR:-$REPO/.build/mas}"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

VERSION=""; BUILDNUM=""; UPLOAD=1; TESTS=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-upload) UPLOAD=0 ;;
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
TAG="mas-v$VERSION-$BUILDNUM"
VERS=(MAS_MARKETING_VERSION="$VERSION" MAS_BUILD_NUMBER="$BUILDNUM")

# ---------------------------------------------------------------------------------------------------------------------------- 1
step "1  preflight"
command -v xcodegen >/dev/null || die "xcodegen is not installed"
[ -z "$(git status --porcelain)" ] || die "the git tree is not clean"
[ "$(git branch --show-current)" = main ] || die "releases are cut from main"
git fetch --quiet origin main --tags || die "fetching origin failed"
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || die "HEAD is not origin/main (pull or push first)"
xcodegen generate >/dev/null
[ -z "$(git status --porcelain)" ] || die "xcodegen generate changed tracked files (the project or an Info.plist); regenerate and commit them first"
# Local tags (just refreshed from origin) plus the remote's own list, so a tag made elsewhere is never missed.
all_tags="$( { git tag --list 'mas-v*'; git ls-remote --tags origin 'mas-v*' | sed 's|.*refs/tags/||; s/\^{}$//'; } | grep -E '^mas-v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' | sort -uV || true)"
last_tag="$(printf '%s\n' "$all_tags" | sed '/^$/d' | tail -1)"
if [ -n "$last_tag" ]; then
  last_build="$(printf '%s\n' "$all_tags" | sed '/^$/d; s/.*-//' | sort -n | tail -1)"
  [ "$BUILDNUM" -gt "$last_build" ] || die "build $BUILDNUM is not greater than the last upload's build $last_build ($last_tag); App Store Connect rejects it"
  last_version="${last_tag#mas-v}"; last_version="${last_version%-*}"
  [ "$(printf '%s\n%s\n' "$last_version" "$VERSION" | sort -V | head -1)" = "$last_version" ] || die "version $VERSION is lower than the last upload's $last_version"
fi
! git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists"
# The project must keep the shared iCloud keychain group in Distribution only.
scripts/mas-entitlement-check.sh --project

# ---------------------------------------------------------------------------------------------------------------------------- 2
step "2  version $VERSION (build $BUILDNUM)"
echo "passed to xcodebuild as ${VERS[*]}; project.yml is not edited"

# ---------------------------------------------------------------------------------------------------------------------------- 3
if [ "$TESTS" = 1 ]; then
  step "3  lint and tests"
  scripts/lint-mac.sh
  swift test --package-path Packages/WheelhouseKit
  # WheelhouseMASTests launches the app (a Debug build, a different bundle ID from the one archived below). Quit any other
  # Wheelhouse first; it never touches the Distribution product.
  xcodebuild test -project Wheelhouse.xcodeproj -scheme WheelhouseMAS -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$BUILD/test-derived"
else
  step "3  lint and tests (skipped)"
fi

# ---------------------------------------------------------------------------------------------------------------------------- 4
step "4  archive (Distribution configuration)"
rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$BUILD"
xcodebuild archive -project Wheelhouse.xcodeproj -scheme WheelhouseMAS -configuration Distribution \
  -archivePath "$ARCHIVE" -derivedDataPath "$DD" -destination 'generic/platform=macOS' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" "${VERS[@]}" | tail -3
[ -d "$ARCHIVE/Products/Applications/Wheelhouse.app" ] || die "the archive holds no Wheelhouse.app"

# ---------------------------------------------------------------------------------------------------------------------------- 5
step "5  entitlement check on the archived app"
scripts/mas-entitlement-check.sh "$ARCHIVE"
ARCHAPP="$ARCHIVE/Products/Applications/Wheelhouse.app"
plist_get() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
for b in "$ARCHAPP" "$ARCHAPP"/Contents/PlugIns/*.appex; do
  [ "$(plist_get "$b" CFBundleShortVersionString)" = "$VERSION" ] && [ "$(plist_get "$b" CFBundleVersion)" = "$BUILDNUM" ] \
    || die "$(basename "$b") is $(plist_get "$b" CFBundleShortVersionString) ($(plist_get "$b" CFBundleVersion)), not $VERSION ($BUILDNUM)"
done

# ---------------------------------------------------------------------------------------------------------------------------- 6
# The archive is signed for development; the export re-signs it for the store. Export to a folder FIRST and check what the export
# really signed (strict: no get-task-allow, the exact App Store profile) before anything is uploaded.
step "6  export to $EXPORT and check the signed product"
OPTS="$BUILD/ExportOptions-AppStore-export.plist"
cp "$REPO/scripts/ExportOptions-AppStore.plist" "$OPTS"
/usr/libexec/PlistBuddy -c "Set :destination export" "$OPTS"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OPTS" -exportPath "$EXPORT" -allowProvisioningUpdates | tail -5
PKG="$(find "$EXPORT" -maxdepth 1 -name '*.pkg' | head -1)"
[ -n "$PKG" ] || die "the export produced no .pkg"
rm -rf "$BUILD/pkg-expanded"
pkgutil --expand-full "$PKG" "$BUILD/pkg-expanded"
EXPAPP="$(find "$BUILD/pkg-expanded" -maxdepth 4 -name Wheelhouse.app -type d | head -1)"
[ -n "$EXPAPP" ] || die "no Wheelhouse.app inside the exported package"
scripts/mas-entitlement-check.sh "$EXPAPP"
# Never open the .pkg or the expanded app on your own macOS user: it is a Distribution build (see the header).

# ---------------------------------------------------------------------------------------------------------------------------- 7
if [ "$UPLOAD" = 0 ]; then
  echo
  echo "Exported and checked: $PKG (nothing was uploaded, no tag was created)."
  exit 0
fi
step "7  upload to App Store Connect"
read -r -p "Upload Wheelhouse for Mac (App Store) $VERSION (build $BUILDNUM) to App Store Connect? A build number can be used once. Type the version to confirm: " typed < /dev/tty
[ "$typed" = "$VERSION" ] || die "confirmation did not match; nothing was uploaded"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$REPO/scripts/ExportOptions-AppStore.plist" -exportPath "$BUILD/upload" -allowProvisioningUpdates | tail -5 \
  || die "the upload failed; if App Store Connect accepted the binary anyway the build number $BUILDNUM is used up: use a higher one"
git tag -a "$TAG" -m "Wheelhouse for Mac (App Store) $VERSION build $BUILDNUM"
cat <<EOF

Uploaded Wheelhouse $VERSION (build $BUILDNUM) to App Store Connect and tagged $TAG locally.

Next:
  1. Push the tag yourself when you are happy:   git push origin $TAG
  2. App Store Connect > Wheelhouse > TestFlight > macOS: wait for the build to finish processing (a few minutes to an hour),
     answer the export compliance question if it asks (the app declares no non-exempt encryption), then add it to an internal group.
  3. Install it from TestFlight on a SEPARATE macOS user, never on the user that has the real ~/.kube. On that build run:
       codesign --verify -R='anchor apple generic and identifier "com.ahmadrezaei.wheelhouse" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists' /Applications/Wheelhouse.app && echo MAS-signed
     (a plain codesign -d -r- is not enough: its default requirement lists that OID as an alternative). If it fails, the
     safety gate stays on. The rest is design/mac/RELEASE-CHECKLIST-MAS.md.
EOF
