#!/bin/bash
# Vendors SwiftTerm without its SwiftPM build-tool plugin into Packages/Vendor/SwiftTerm.
#
#   scripts/vendor-swiftterm.sh            # vendor the pinned release below
#   scripts/vendor-swiftterm.sh --check    # verify the committed copy matches a fresh vendoring
#
# Upgrading is a deliberate change: edit TAG, COMMIT and SHA256 together, run the script, review the diff.
# The script downloads only from https://github.com/migueldeicaza/SwiftTerm, verifies the tag's commit and
# the tarball checksum, builds upstream's build-info generator once with swiftc, and commits its two outputs
# (Generated/SwiftTermBuildInfo.swift, Generated/SwiftTermTerminfo.swift) so no plugin is needed.
set -euo pipefail

TAG="v1.99.2"
COMMIT="a183c15b52858530a17de57dcc72b93eeebc9857"
SHA256="b819f0143fd14c929e9ab5422f2c0b3a01f424d5721e9ae2e5f3f428a96312dc"   # SHA-256 of the GitHub commit tarball
REPO="https://github.com/migueldeicaza/SwiftTerm"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Packages/Vendor/SwiftTerm"
MODE="vendor"
[ "${1:-}" = "--check" ] && MODE="check"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/swiftterm-vendor.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

echo "Checking that tag $TAG resolves to $COMMIT"
REMOTE="$(git ls-remote "$REPO" "refs/tags/$TAG" | cut -f1)"
[ "$REMOTE" = "$COMMIT" ] || { echo "error: tag $TAG is '$REMOTE', expected $COMMIT" >&2; exit 1; }

echo "Downloading $COMMIT"
curl -fsSL -o "$WORK/src.tgz" "$REPO/archive/$COMMIT.tar.gz"
ACTUAL="$(shasum -a 256 "$WORK/src.tgz" | cut -d' ' -f1)"
[ "$ACTUAL" = "$SHA256" ] || { echo "error: checksum mismatch ($ACTUAL, expected $SHA256)" >&2; exit 1; }

mkdir "$WORK/up"
tar xzf "$WORK/src.tgz" -C "$WORK/up" --strip-components=1
UP="$WORK/up"

echo "Building the build-info generator"
swiftc -O -parse-as-library -o "$WORK/generator" "$UP"/Sources/SwiftTermBuildInfoGenerator/*.swift

OUT="$WORK/out"
mkdir -p "$OUT/Sources" "$WORK/gen"
# The tarball has no .git, so the build information comes from the pinned values.
SWIFTTERM_BUILD_TAG="$TAG" SWIFTTERM_BUILD_COMMIT="$COMMIT" SWIFTTERM_BUILD_BRANCH="$TAG" SWIFTTERM_BUILD_DIRTY=0 \
  "$WORK/generator" "$UP" "$WORK/gen/SwiftTermBuildInfo.swift" "$WORK/gen/SwiftTermTerminfo.swift"

rsync -a "$UP/Sources/SwiftTerm" "$OUT/Sources/"
mkdir -p "$OUT/Sources/SwiftTerm/Generated"
cp "$WORK/gen/SwiftTermBuildInfo.swift" "$WORK/gen/SwiftTermTerminfo.swift" "$OUT/Sources/SwiftTerm/Generated/"
cp "$UP/LICENSE" "$OUT/LICENSE"
cp "$UP/swifterm-terminfo" "$OUT/swifterm-terminfo"   # generator input, kept so the generated table can be reproduced

cat > "$OUT/Package.swift" <<'SWIFT'
// swift-tools-version:6.2
// Plugin-free manifest for the vendored SwiftTerm (see VENDORED.md and scripts/vendor-swiftterm.sh).
// Upstream runs SwiftTermBuildInfoGenerator through a build-tool plugin; its two outputs are committed
// under Sources/SwiftTerm/Generated instead, so Xcode never asks to trust a plugin.
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"]),
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: [
                "Mac/README.md",
                "Apple/Metal/Shaders.metal",
                "Documentation.docc",
            ]
        ),
        .testTarget(
            name: "SwiftTermVendorTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermVendorTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
SWIFT

mkdir -p "$OUT/Tests/SwiftTermVendorTests"
cat > "$OUT/Tests/SwiftTermVendorTests/CompileTests.swift" <<'SWIFT'
import Testing
@testable import SwiftTerm

/// Minimal proof that the plugin-free vendored copy builds and that the headless core runs.
@Suite struct VendoredSwiftTermTests {
    @Test func headlessTerminalProcessesInput() {
        let terminal = HeadlessTerminal(queue: .main) { _ in }
        terminal.terminal.feed(text: "hello")
        #expect(terminal.terminal.getLine(row: 0)?.translateToString(trimRight: true) == "hello")
    }
}
SWIFT

cat > "$OUT/VENDORED.md" <<MD
# Vendored SwiftTerm

- Upstream: $REPO (MIT, see LICENSE)
- Tag: $TAG
- Commit: $COMMIT
- Tarball SHA-256: $SHA256
- Produced by: scripts/vendor-swiftterm.sh (do not edit these files by hand)

Changes from upstream:
- Package.swift is replaced by a plugin-free manifest (iOS 27 and macOS 27, no swift-png, no executables).
- Sources/SwiftTerm/Generated/SwiftTermBuildInfo.swift and SwiftTermTerminfo.swift are the outputs of upstream's
  SwiftTermBuildInfoGenerator, run once with the tag and commit above and committed.
- swifterm-terminfo is the generator's input, kept for reference.
- Everything else under Sources/SwiftTerm is byte-for-byte upstream. Tests/SwiftTermVendorTests is ours.
MD

if [ "$MODE" = "check" ]; then
  diff -r -x .build -x .swiftpm "$OUT" "$DEST" && echo "Vendored copy matches $TAG"
  exit $?
fi

rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
cp -R "$OUT" "$DEST"
echo "Vendored SwiftTerm $TAG into $DEST"
