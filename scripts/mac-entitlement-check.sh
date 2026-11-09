#!/bin/bash
# Build checks for the dev-build safety rule and the entitlements (ARCHITECTURE-MAC sections 2.6 and 13.2, layer 4).
#
#   scripts/mac-entitlement-check.sh <Wheelhouse.app> [--config Debug|Profile|Release|Distribution]
#
# Fails when, for the given app bundle and configuration:
#  - the signed entitlements differ from the expected set (any extra key, or the shared iCloud group in a Debug or Profile build);
#  - Info.plist WHDevSafety is not YES (every configuration except Distribution) or not NO (Distribution);
#  - the bundle ID, Sparkle feed or test-kubeconfig keys do not match the configuration;
#  - the binary contains a test-hook symbol (WHTestHook, GangwayTestHooks, autoApprove) or the Gangway auto-approve launch argument
#    (WHGangwayAutoApprove) in any configuration except Debug.
# `--config` defaults to $CONFIGURATION, then to Debug when the bundle ID ends in .debug.
# Meant for `build` output. A Debug app re-signed by Xcode for hosted tests (temporary-exception entitlements, no hardened runtime) is
# accepted for Debug only. Runs on the built product; it never launches the app and never reads ~/.kube.
set -euo pipefail

APP="${1:-}"; shift || true
CONFIG="${CONFIGURATION:-}"
while [ $# -gt 0 ]; do
  case "$1" in --config) CONFIG="$2"; shift 2 ;; *) echo "unknown option: $1" >&2; exit 2 ;; esac
done
[ -d "$APP" ] || { echo "usage: $0 <Wheelhouse.app> [--config <name>]" >&2; exit 2; }
PLIST="$APP/Contents/Info.plist"
pb() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""; }

BID="$(pb CFBundleIdentifier)"
if [ -z "$CONFIG" ]; then case "$BID" in *.debug) CONFIG=Debug ;; *) CONFIG=Release ;; esac; fi
case "$CONFIG" in Debug|Profile|Release|Distribution) ;; *) echo "unknown configuration: $CONFIG" >&2; exit 2 ;; esac

FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "ok:   $*"; }

TEAM=JCZY58QP3L
case "$CONFIG" in
  Debug|Profile)
    WANT_BID=com.ahmadrezaei.wheelhouse.mac.debug
    WANT_KEYCHAIN="$TEAM.com.ahmadrezaei.wheelhouse.mac.debug"
    WANT_GROUP="$TEAM.com.ahmadrezaei.wheelhouse.debug" ;;
  Release|Distribution)
    WANT_BID=com.ahmadrezaei.wheelhouse.mac
    WANT_KEYCHAIN="$TEAM.com.ahmadrezaei.wheelhouse.mac $TEAM.com.ahmadrezaei.wheelhouse.shared"
    WANT_GROUP="$TEAM.com.ahmadrezaei.wheelhouse" ;;
esac

# ---- Info.plist
[ "$BID" = "$WANT_BID" ] && ok "bundle ID $BID" || fail "bundle ID is '$BID', want $WANT_BID ($CONFIG)"
GATE="$(pb WHDevSafety)"
if [ "$CONFIG" = Distribution ]; then
  [ "$GATE" = "NO" ] && ok "WHDevSafety = NO (Distribution)" || fail "Distribution must have WHDevSafety = NO (got '$GATE')"
  [ -z "$(pb WHDefaultTestKubeconfig)" ] && ok "no test kubeconfig key" || fail "Distribution Info.plist has WHDefaultTestKubeconfig"
  [ -z "$(pb WHPerfScenarioDirectory)" ] && ok "no perf scenario directory" || fail "Distribution Info.plist has WHPerfScenarioDirectory"
  [ "$(pb SUFeedURL)" = "https://ahmadrezaei.github.io/wheelhouse/mac/appcast.xml" ] && ok "Sparkle feed URL" || fail "Distribution SUFeedURL must be https://ahmadrezaei.github.io/wheelhouse/mac/appcast.xml (got '$(pb SUFeedURL)')"
  [ "$(pb SURequireSignedFeed)" = "true" ] && ok "SURequireSignedFeed" || fail "Distribution must set SURequireSignedFeed"
  [ "$(pb SUVerifyUpdateBeforeExtraction)" = "true" ] && ok "SUVerifyUpdateBeforeExtraction" || fail "Distribution must set SUVerifyUpdateBeforeExtraction"
else
  [ "$GATE" = "YES" ] && ok "WHDevSafety = YES ($CONFIG)" || fail "$CONFIG must have WHDevSafety = YES (got '$GATE')"
fi
case "$CONFIG" in
  Debug|Profile)
    [ -z "$(pb SUFeedURL)" ] && ok "no Sparkle feed" || fail "$CONFIG must have no SUFeedURL"
    [ "$(pb SUEnableAutomaticChecks)" = "false" ] || [ "$(pb SUEnableAutomaticChecks)" = "NO" ] && ok "automatic update checks off" || fail "$CONFIG must have SUEnableAutomaticChecks NO"
    [ "$(pb WHKeychainGroupSuffix)" = "com.ahmadrezaei.wheelhouse.mac.debug" ] && ok "keychain group suffix is the debug group" || fail "WHKeychainGroupSuffix is not the debug group"
    [ "$(pb WHKeychainPrivateGroupSuffix)" = "com.ahmadrezaei.wheelhouse.mac.debug" ] && ok "private keychain suffix is the debug group" || fail "WHKeychainPrivateGroupSuffix is not the debug group" ;;
esac

# ---- entitlements (signed)
ENT="$(mktemp)"; trap 'rm -f "$ENT"' EXIT
if ! codesign -d --entitlements "$ENT" --xml "$APP" >/dev/null 2>&1 || [ ! -s "$ENT" ]; then
  # Older codesign prints to stdout with :- ; fall back.
  codesign -d --entitlements :- "$APP" >"$ENT" 2>/dev/null || true
fi
if [ ! -s "$ENT" ]; then
  fail "could not read the signed entitlements (is the app signed?)"
else
  python3 -I - "$ENT" "$CONFIG" "$TEAM" "$WANT_KEYCHAIN" "$WANT_GROUP" "$WANT_BID" <<'PY' || FAIL=1
import sys, plistlib
path, config, team, want_keychain, want_group, want_bid = sys.argv[1:7]
raw = open(path, 'rb').read()
raw = raw[raw.find(b'<?xml'):] if b'<?xml' in raw else raw
ent = plistlib.loads(raw)
bad = []
appid = "com.apple.application-identifier"
if ent.get(appid) != team + "." + want_bid: bad.append("application-identifier is %s, want %s.%s" % (ent.get(appid), team, want_bid))
allowed = {appid, "com.apple.developer.team-identifier", "keychain-access-groups", "com.apple.security.application-groups"}
if config in ("Debug", "Profile"): allowed.add("com.apple.security.get-task-allow")
# Xcode re-signs a Debug app that hosts tests and injects com.apple.security.temporary-exception.* entitlements (and drops the
# hardened runtime flag). Those are accepted for Debug ONLY; the check is meant for `build` output.
if config == "Debug": allowed |= {k for k in ent if k.startswith("com.apple.security.temporary-exception.")}
extra = sorted(set(ent) - allowed)
if extra: bad.append("unexpected entitlement keys: %s" % ", ".join(extra))
groups = ent.get("keychain-access-groups", [])
if sorted(groups) != sorted(want_keychain.split()): bad.append("keychain-access-groups = %s, want %s" % (groups, want_keychain.split()))
if config in ("Debug", "Profile") and any(g.endswith(".shared") or g.endswith("wheelhouse.shared") for g in groups): bad.append("a Debug/Profile build carries the shared iCloud keychain group")
if sorted(ent.get("com.apple.security.application-groups", [])) != [want_group]: bad.append("application-groups = %s, want [%s]" % (ent.get("com.apple.security.application-groups"), want_group))
if ent.get("com.apple.developer.team-identifier") != team: bad.append("team identifier is not " + team)
if config in ("Release", "Distribution") and ent.get("com.apple.security.get-task-allow"): bad.append("get-task-allow in a %s build" % config)
for k in ("com.apple.security.app-sandbox", "com.apple.security.cs.allow-jit", "com.apple.security.cs.disable-library-validation"):
    if k in ent: bad.append("forbidden entitlement " + k)
if bad:
    for b in bad: print("FAIL: " + b, file=sys.stderr)
    sys.exit(1)
print("ok:   entitlements match the %s set" % config)
PY
fi

# ---- hardened runtime
SIGINFO="$(codesign -dv "$APP" 2>&1 || true)"
case "$SIGINFO" in
  *"flags="*runtime*) ok "hardened runtime" ;;
  *) if [ "$CONFIG" = Debug ] && grep -q 'temporary-exception' "$ENT" 2>/dev/null; then ok "hardened runtime absent: Xcode test-host signing (Debug only)"; else fail "hardened runtime flag missing"; fi ;;
esac

# ---- Distribution only (M2): Developer ID signature, profile, runtime on every Mach-O, no Sparkle XPC services, bundled helm
if [ "$CONFIG" = Distribution ]; then
  [ -n "$(pb SUPublicEDKey)" ] && ok "Sparkle public key set" || fail "Distribution must have SUPublicEDKey"
  [ "$(pb SUShowReleaseNotes)" = "false" ] && ok "SUShowReleaseNotes is false" || fail "SUShowReleaseNotes must be false"
  case "$(codesign -dvv "$APP" 2>&1 || true)" in
    *"Authority=Developer ID Application"*"($TEAM)"*) ok "signed with Developer ID Application ($TEAM)" ;;
    *) fail "the app is not signed with a Developer ID Application certificate of team $TEAM" ;;
  esac
  XPC="$(find "$APP" -name '*.xpc' 2>/dev/null || true)"
  [ -z "$XPC" ] && ok "no XPC services embedded (Sparkle's are stripped)" || fail "embedded XPC services: $XPC"
  [ -x "$APP/Contents/Helpers/helm" ] && ok "bundled helm present" || fail "Contents/Helpers/helm is missing"
  PROFILE="$APP/Contents/embedded.provisionprofile"
  if [ -f "$PROFILE" ]; then
    python3 -I - "$PROFILE" "$TEAM.$WANT_BID" <<'PY' || FAIL=1
import sys, subprocess, plistlib
path, appid = sys.argv[1:3]
raw = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True).stdout
p = plistlib.loads(raw)
bad = []
if "ProvisionedDevices" in p: bad.append("the profile is a development profile (it lists devices)")
if p.get("ProvisionsAllDevices") is not True: bad.append("the profile does not have ProvisionsAllDevices = true (not a Developer ID profile)")
if p.get("Entitlements", {}).get("com.apple.application-identifier") != appid: bad.append("profile application-identifier is %s" % p.get("Entitlements", {}).get("com.apple.application-identifier"))
if p.get("Entitlements", {}).get("com.apple.security.get-task-allow"): bad.append("profile allows get-task-allow")
if bad:
    for b in bad: print("FAIL: " + b, file=sys.stderr)
    sys.exit(1)
print("ok:   embedded provisioning profile is a Developer ID profile for " + appid)
PY
  else
    fail "embedded.provisionprofile is missing (keychain-access-groups needs a profile)"
  fi
  # Nested code carries exactly its own entitlements (no injected application-identifier, nothing extra).
  nested_ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null | python3 -I -c '
import sys, plistlib, json
d = sys.stdin.buffer.read()
print(json.dumps(plistlib.loads(d[d.find(b"<?xml"):]) if b"<?xml" in d else {}, sort_keys=True))'; }
  GRP="[\"$TEAM.com.ahmadrezaei.wheelhouse\"]"
  check_nested() { # <relative path> <expected json>
    got="$(nested_ents "$APP/$1")"
    [ "$got" = "$2" ] && ok "entitlements of $1" || fail "$1 entitlements are $got, want $2"
  }
  check_nested Contents/Helpers/wh-pty-exec '{}'
  check_nested Contents/Helpers/wheelhouse-mcp "{\"com.apple.security.application-groups\": $GRP}"
  check_nested Contents/PlugIns/WheelhouseMacWidgets.appex "{\"com.apple.security.app-sandbox\": true, \"com.apple.security.application-groups\": $GRP}"
  while IFS= read -r f; do
    info="$(codesign -dvv "$f" 2>&1 || true)"
    case "$info" in *"flags="*"(runtime"*) ;; *) fail "no hardened runtime: ${f#$APP/}" ;; esac
    case "$info" in *"Timestamp="*) ;; *) fail "no secure timestamp: ${f#$APP/}" ;; esac
    case "$info" in *"Authority=Developer ID Application"*"($TEAM)"*) ;; *) fail "not signed with Developer ID: ${f#$APP/}" ;; esac
  done < <(find "$APP" -type f -exec sh -c 'file -b "$1" | grep -q "^Mach-O" && printf "%s\n" "$1"' _ {} \;)
  ok "every Mach-O was checked for runtime, timestamp and Developer ID signature"
fi

# ---- test-hook symbols (compiled only under WH_TEST_HOOKS, which only Debug sets)
HOOKS=0
while IFS= read -r f; do
  SYMS="$(nm -m "$f" 2>/dev/null || true)"     # captured first: `nm | grep -q` under pipefail would die of SIGPIPE and report "clean"
  case "$SYMS" in *WHTestHook*|*GangwayTestHooks*|*autoApprove*) HOOKS=1; echo "  test-hook symbol in $f" >&2 ;; esac
  # The Gangway auto-approve launch argument is a string literal: a stripped binary has no symbol for it, so look for the text too.
  if grep -aq 'WHGangwayAutoApprove' "$f" 2>/dev/null; then HOOKS=1; echo "  Gangway auto-approve launch argument in $f" >&2; fi
done < <(find "$APP/Contents/MacOS" "$APP/Contents/Helpers" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
if [ "$CONFIG" = Debug ]; then ok "test hooks allowed in Debug (symbols present: $([ "$HOOKS" = 1 ] && echo yes || echo no))"; elif [ "$HOOKS" = 0 ]; then ok "no test-hook symbols"; else fail "$CONFIG build contains test-hook symbols"; fi

[ "$FAIL" = 0 ] && echo "mac-entitlement-check: PASS ($CONFIG)" || { echo "mac-entitlement-check: FAIL ($CONFIG)" >&2; exit 1; }
