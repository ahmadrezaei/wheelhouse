#!/bin/bash
# Release checks for the Mac App Store edition (design/mac/MAS-EDITION.md section 4). The GitHub edition has its own script,
# scripts/mac-entitlement-check.sh, which this one never replaces.
#
#   scripts/mas-entitlement-check.sh <Wheelhouse.app | Wheelhouse.xcarchive>
#   scripts/mas-entitlement-check.sh --project
#
# Bundle mode checks a DISTRIBUTION build of the sandboxed app (an app, or an archive: its single app is used). It is strictest on
# an exported app: expand the exported .pkg with `pkgutil --expand-full` and pass the Wheelhouse.app inside. It fails on:
#  - any signed entitlement outside the Distribution list (sandbox, network client and server, user-selected read-write,
#    app-scope bookmarks, keychain-access-groups, application-groups), apart from the two keys Xcode injects
#    (com.apple.application-identifier, com.apple.developer.team-identifier); get-task-allow is tolerated only inside an archive,
#    which is signed for development and re-signed by the export;
#  - any com.apple.security.temporary-exception.* key;
#  - an application identifier other than JCZY58QP3L.com.ahmadrezaei.wheelhouse, or `.mas` not first in keychain-access-groups
#    (the keychain default group is the FIRST one listed), or an app group other than the `.mas` one;
#  - anything in Contents/Helpers, any other executable in Contents/MacOS, Sparkle (framework, XPC services, SU* Info.plist keys);
#  - WHDevSafety other than NO, a non-empty WHDefaultTestKubeconfig or WHPerfScenarioDirectory;
#  - the test-hook symbols (WHTestHook, GangwayTestHooks, autoApprove) or the WHGangwayAutoApprove launch argument in a binary;
#  - the widget (Contents/PlugIns/*.appex): anything but the sandbox and the `.mas` app group in its entitlements;
#  - a missing or invalid code signature or embedded provisioning profile, or a missing hardened runtime flag.
# It reads the built product only. It never launches the app and never reads ~/.kube or .secrets/.
#
# --project mode reads `xcodebuild -showBuildSettings` for every configuration of the WheelhouseMAS and WheelhouseMASWidgets targets (about 10 to 40 seconds) and
# fails when a non-Distribution configuration's entitlements file mentions the shared iCloud keychain group (.shared) or when
# Distribution's file does not list `.mas` first, along with the bundle IDs, the safety-gate setting and the Distribution key set.
# It needs no signing and builds nothing. It is NOT part of scripts/lint-mac.sh (too slow for it): run it before a release;
# scripts/release-mac-appstore.sh does.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
export MAS_CHECK_REPO="$REPO"
exec python3 -I - "$@" <<'PY'
import glob, json, os, plistlib, subprocess, sys

TEAM = "JCZY58QP3L"
BUNDLE = "com.ahmadrezaei.wheelhouse"
APP_GROUP = TEAM + ".com.ahmadrezaei.wheelhouse.mas"
SHARED_GROUP = TEAM + ".com.ahmadrezaei.wheelhouse.shared"
INJECTED = {"com.apple.application-identifier", "com.apple.developer.team-identifier"}
APP_ENTITLEMENTS = {
    "com.apple.security.app-sandbox",
    "com.apple.security.network.client",
    "com.apple.security.network.server",
    "com.apple.security.files.user-selected.read-write",
    "com.apple.security.files.bookmarks.app-scope",
    "keychain-access-groups",
    "com.apple.security.application-groups",
}
WIDGET_ENTITLEMENTS = {"com.apple.security.app-sandbox", "com.apple.security.application-groups"}
CONFIGURATIONS = ["Debug", "Profile", "Release", "Distribution"]

failed = False
def fail(msg):
    global failed
    failed = True
    print("FAIL: " + msg, file=sys.stderr)
def ok(msg): print("ok:   " + msg)
def check(cond, good, bad):
    ok(good) if cond else fail(bad)

def run(*cmd):
    return subprocess.run(cmd, capture_output=True)

def load_plist_bytes(raw):
    i = raw.find(b"<?xml")
    return plistlib.loads(raw[i:]) if i >= 0 else {}

def signed_entitlements(path):
    r = run("codesign", "-d", "--entitlements", "-", "--xml", path)
    return load_plist_bytes(r.stdout) if r.returncode == 0 else None

def profile_of(path):
    p = os.path.join(path, "Contents", "embedded.provisionprofile")
    if not os.path.isfile(p): return None
    r = run("security", "cms", "-D", "-i", p)
    return plistlib.loads(r.stdout) if r.returncode == 0 and r.stdout else {}

def check_signature(label, path):
    r = run("codesign", "--verify", "--strict", "--deep", path)
    check(r.returncode == 0, label + " code signature is valid", label + " has no valid code signature (%s)" % (r.stderr.decode().strip().splitlines() or ["unsigned"])[-1])
    flags = [l for l in run("codesign", "-dv", path).stderr.decode().splitlines() if "flags=" in l]
    check(bool(flags) and "runtime" in flags[0], label + " has the hardened runtime", label + " is missing the hardened runtime flag")

def check_profile(label, path, appid, archive=False):
    prof = profile_of(path)
    if prof is None:
        fail(label + " has no embedded.provisionprofile (keychain-access-groups and the app group need one)")
    elif not prof:
        fail(label + " embedded.provisionprofile could not be decoded")
    else:
        got = prof.get("Entitlements", {}).get("com.apple.application-identifier")
        # A development-signed archive uses the automatic wildcard team profile; the exported app must carry the exact identifier.
        accepted = {appid, TEAM + ".*"} if archive else {appid}
        check(got in accepted, label + " profile application identifier is " + str(got), label + " profile application identifier is %s, want %s" % (got, " or ".join(sorted(accepted))))

def check_entitlements(label, path, allowed, want_appid, groups_rule, archive):
    ent = signed_entitlements(path)
    if ent is None or not ent:
        fail(label + ": could not read the signed entitlements (is it signed?)")
        return
    appid = ent.get("com.apple.application-identifier")
    check(appid == want_appid, label + " application identifier is " + want_appid, label + " application identifier is %s, want %s" % (appid, want_appid))
    check(ent.get("com.apple.developer.team-identifier") == TEAM, label + " team identifier", label + " team identifier is %s, want %s" % (ent.get("com.apple.developer.team-identifier"), TEAM))
    temp = sorted(k for k in ent if k.startswith("com.apple.security.temporary-exception."))
    check(not temp, label + " has no temporary-exception entitlement", label + " carries temporary-exception entitlements (a Debug/Profile signature?): " + ", ".join(temp))
    extra = set(ent) - allowed - INJECTED - set(temp)
    if archive and "com.apple.security.get-task-allow" in extra:
        print("note: %s: get-task-allow in an archive (development signature; the export re-signs it): not checked here" % label)
        extra.discard("com.apple.security.get-task-allow")
    check(not extra, label + " entitlements are within the Distribution list", label + " has entitlements outside the Distribution list: " + ", ".join(sorted(extra)))
    missing = sorted(allowed - set(ent))
    check(not missing, label + " has every Distribution entitlement", label + " is missing entitlements: " + ", ".join(missing))
    if "com.apple.security.app-sandbox" in ent:
        check(ent["com.apple.security.app-sandbox"] is True, label + " is sandboxed", label + " app-sandbox is not true")
    groups_rule(label, ent)

def app_groups_rule(label, ent):
    kc = ent.get("keychain-access-groups", [])
    check(kc[:1] == [APP_GROUP], label + " lists .mas first in keychain-access-groups", label + " keychain-access-groups starts with %s, want %s first" % (kc[:1], APP_GROUP))
    check(sorted(kc) == sorted([APP_GROUP, SHARED_GROUP]), label + " keychain-access-groups are .mas and .shared", label + " keychain-access-groups are %s, want [%s, %s]" % (kc, APP_GROUP, SHARED_GROUP))
    ag = ent.get("com.apple.security.application-groups", [])
    check(ag == [APP_GROUP], label + " app group is .mas", label + " application-groups are %s, want [%s]" % (ag, APP_GROUP))

def widget_groups_rule(label, ent):
    ag = ent.get("com.apple.security.application-groups", [])
    check(ag == [APP_GROUP], label + " app group is .mas only", label + " application-groups are %s, want [%s]" % (ag, APP_GROUP))

def has_sparkle_key(info):
    return sorted(k for k in info if k.startswith("SU") and k[2:3].isupper())

def check_info(label, info, want_bid):
    check(info.get("CFBundleIdentifier") == want_bid, label + " bundle ID is " + want_bid, label + " bundle ID is %s, want %s" % (info.get("CFBundleIdentifier"), want_bid))
    sparkle = has_sparkle_key(info)
    check(not sparkle, label + " has no Sparkle Info.plist keys", label + " has Sparkle keys: " + ", ".join(sparkle))

def scan_binaries(label, bundle):
    found = []
    macos = os.path.join(bundle, "Contents", "MacOS")
    for name in sorted(os.listdir(macos)) if os.path.isdir(macos) else []:
        f = os.path.join(macos, name)
        r = run("nm", "-m", f)   # captured first so a closed pipe can't pass for "clean"
        if r.returncode != 0: found.append("nm failed on " + f)
        syms = r.stdout.decode(errors="replace")
        if any(s in syms for s in ("WHTestHook", "GangwayTestHooks", "autoApprove")): found.append("test-hook symbol in " + f)
        with open(f, "rb") as fh:
            if b"WHGangwayAutoApprove" in fh.read(): found.append("Gangway auto-approve launch argument in " + f)
    frameworks = os.path.join(bundle, "Contents", "Frameworks")
    for d, _, names in os.walk(frameworks):
        for n in names:
            f = os.path.join(d, n)
            if run("file", "-b", f).stdout.startswith(b"Mach-O"):
                r = run("nm", "-m", f)
                if r.returncode != 0 or any(x in r.stdout.decode(errors="replace") for x in ("WHTestHook", "GangwayTestHooks", "autoApprove")): found.append("test hook or unreadable symbols in " + f)
    check(not found, label + " has no test-hook symbols", label + " contains test hooks: " + "; ".join(found))

def bundle_mode(target):
    archive = target.rstrip("/").endswith(".xcarchive")
    app = target
    if archive:
        apps = glob.glob(os.path.join(target, "Products", "Applications", "*.app"))
        if len(apps) != 1:
            print("usage: the archive must hold exactly one app (found %d)" % len(apps), file=sys.stderr); sys.exit(2)
        app = apps[0]
    if not os.path.isdir(app):
        print("usage: mas-entitlement-check.sh <Wheelhouse.app | Wheelhouse.xcarchive> | --project", file=sys.stderr); sys.exit(2)
    print("checking " + app + (" (from an archive)" if archive else ""))
    contents = os.path.join(app, "Contents")
    with open(os.path.join(contents, "Info.plist"), "rb") as fh: info = plistlib.load(fh)

    # ---- Info.plist
    check_info("app", info, BUNDLE)
    gate = info.get("WHDevSafety")
    check(gate in ("NO", False), "WHDevSafety = NO (Distribution)", "WHDevSafety is %r, a Distribution build must have NO" % (gate,))
    for key in ("WHDefaultTestKubeconfig", "WHPerfScenarioDirectory"):
        check(not info.get(key), "no " + key, "Info.plist has %s = %r" % (key, info.get(key)))
    check(info.get("WHKeychainGroupSuffix") == "com.ahmadrezaei.wheelhouse.shared", "keychain group suffix is .shared", "WHKeychainGroupSuffix is %r" % info.get("WHKeychainGroupSuffix"))
    check(info.get("WHKeychainPrivateGroupSuffix") == "com.ahmadrezaei.wheelhouse.mas", "private keychain suffix is .mas", "WHKeychainPrivateGroupSuffix is %r" % info.get("WHKeychainPrivateGroupSuffix"))
    check(info.get("WHAppGroup") == APP_GROUP, "WHAppGroup is the .mas group", "WHAppGroup is %r, want %s" % (info.get("WHAppGroup"), APP_GROUP))
    check(info.get("ITSAppUsesNonExemptEncryption") is False, "ITSAppUsesNonExemptEncryption = false", "ITSAppUsesNonExemptEncryption must be false")

    # ---- bundle contents
    helpers = os.path.join(contents, "Helpers")
    leftovers = sorted(os.listdir(helpers)) if os.path.isdir(helpers) else []
    check(not os.path.exists(helpers), "no Contents/Helpers", "Contents/Helpers exists (%s); the sandboxed edition ships no helpers" % (", ".join(leftovers) or "empty"))
    library = os.path.join(contents, "Library")
    check(not os.path.exists(library), "no Contents/Library (login items, launch services)", "Contents/Library exists: " + ", ".join(sorted(os.listdir(library)) if os.path.isdir(library) else []))
    macos = sorted(os.listdir(os.path.join(contents, "MacOS")))
    check(macos == [info.get("CFBundleExecutable")], "Contents/MacOS holds only the app executable", "Contents/MacOS holds %s" % macos)
    sparkle = [os.path.relpath(os.path.join(d, n), app) for d, dirs, names in os.walk(app) for n in dirs + names if "Sparkle" in n or n.endswith(".xpc")]
    check(not sparkle, "no Sparkle and no XPC services", "Sparkle or XPC content in the bundle: " + ", ".join(sorted(sparkle)))
    plugins = sorted(glob.glob(os.path.join(contents, "PlugIns", "*")))
    check(len(plugins) == 1 and plugins[0].endswith(".appex"), "exactly one app extension (the widget)", "PlugIns holds %s" % [os.path.basename(p) for p in plugins])

    # ---- signatures, profile, entitlements
    check_signature("app", app)
    check_profile("app", app, TEAM + "." + BUNDLE, archive)
    check_entitlements("app", app, APP_ENTITLEMENTS, TEAM + "." + BUNDLE, app_groups_rule, archive)
    scan_binaries("app", app)
    for appex in plugins:
        label = "widget " + os.path.basename(appex)
        with open(os.path.join(appex, "Contents", "Info.plist"), "rb") as fh: winfo = plistlib.load(fh)
        check_info(label, winfo, BUNDLE + ".widgets")
        check(winfo.get("WHAppGroup") == APP_GROUP, label + " WHAppGroup is the .mas group", label + " WHAppGroup is %r" % winfo.get("WHAppGroup"))
        check_signature(label, appex)
        check_profile(label, appex, TEAM + "." + BUNDLE + ".widgets", archive)
        check_entitlements(label, appex, WIDGET_ENTITLEMENTS, TEAM + "." + BUNDLE + ".widgets", widget_groups_rule, archive)
        scan_binaries(label, appex)

def build_settings(configuration):
    out = {}
    for target in ("WheelhouseMAS", "WheelhouseMASWidgets"):
        cmd = ["xcodebuild", "-showBuildSettings", "-json", "-project", "Wheelhouse.xcodeproj", "-target", target, "-configuration", configuration]
        r = subprocess.run(cmd, capture_output=True, cwd=os.environ["MAS_CHECK_REPO"])
        if r.returncode != 0:
            return configuration, None, r.stderr.decode(errors="replace").strip().splitlines()[-1:]
        out.update({t["target"]: t["buildSettings"] for t in json.loads(r.stdout)})
    return configuration, out, None

def project_mode():
    results = [build_settings(c) for c in CONFIGURATIONS]   # serial: parallel xcodebuild runs on one project stall each other
    for configuration, targets, error in results:
        if targets is None:
            fail("%s: xcodebuild -showBuildSettings failed: %s" % (configuration, error)); continue
        for name, want_bid_dist, allowed in (("WheelhouseMAS", BUNDLE, APP_ENTITLEMENTS), ("WheelhouseMASWidgets", BUNDLE + ".widgets", WIDGET_ENTITLEMENTS)):
            label = "%s %s" % (configuration, name)
            s = targets.get(name)
            if s is None:
                fail(label + ": the target is missing from the scheme's build settings"); continue
            dist = configuration == "Distribution"
            bid = s.get("PRODUCT_BUNDLE_IDENTIFIER")
            want_bid = want_bid_dist if dist else want_bid_dist.replace(BUNDLE, BUNDLE + ".mas.debug", 1)
            check(bid == want_bid, "%s bundle ID %s" % (label, bid), "%s bundle ID is %s, want %s" % (label, bid, want_bid))
            if name == "WheelhouseMAS":
                want_gate = "NO" if dist else "YES"
                check(s.get("WH_DEV_SAFETY") == want_gate, "%s WH_DEV_SAFETY = %s" % (label, want_gate), "%s WH_DEV_SAFETY is %r, want %s" % (label, s.get("WH_DEV_SAFETY"), want_gate))
                if dist:
                    for key in ("WH_DEFAULT_TEST_KUBECONFIG", "WH_PERF_SCENARIOS"):
                        check(not s.get(key), "%s %s is empty" % (label, key), "%s %s is %r, want empty" % (label, key, s.get(key)))
            path = s.get("CODE_SIGN_ENTITLEMENTS")
            if not path:
                fail(label + ": CODE_SIGN_ENTITLEMENTS is not set"); continue
            full = path if os.path.isabs(path) else os.path.join(s["SRCROOT"], path)
            with open(full, "rb") as fh: raw = fh.read()
            ent = plistlib.loads(raw)
            rel = os.path.relpath(full, s["SRCROOT"])
            if dist:
                keys = set(ent)
                check(keys == allowed, "%s %s has exactly the Distribution key set" % (label, rel), "%s %s keys differ from the Distribution list: extra %s, missing %s" % (label, rel, sorted(keys - allowed), sorted(allowed - keys)))
                if name == "WheelhouseMAS":
                    kc = ent.get("keychain-access-groups", [])
                    check(kc == [APP_GROUP, SHARED_GROUP], "%s %s lists .mas first, then .shared" % (label, rel), "%s %s keychain-access-groups are %s, want [%s, %s]" % (label, rel, kc, APP_GROUP, SHARED_GROUP))
                check(ent.get("com.apple.security.application-groups") == [APP_GROUP], "%s %s app group is .mas" % (label, rel), "%s %s application-groups are %s" % (label, rel, ent.get("com.apple.security.application-groups")))
            else:
                check(b".shared" not in raw, "%s %s does not mention .shared" % (label, rel), "%s %s mentions the shared iCloud keychain group (.shared); only Distribution may" % (label, rel))
                groups = [g for g in ent.get("keychain-access-groups", []) + ent.get("com.apple.security.application-groups", []) if not g.endswith(".mas.debug")]
                check(not groups, "%s %s uses only .mas.debug groups" % (label, rel), "%s %s lists groups other than .mas.debug: %s" % (label, rel, groups))

args = sys.argv[1:]
if args == ["--project"]:
    project_mode()
    mode = "project"
elif len(args) == 1 and not args[0].startswith("-"):
    bundle_mode(args[0])
    mode = "bundle"
else:
    print("usage: mas-entitlement-check.sh <Wheelhouse.app | Wheelhouse.xcarchive> | --project", file=sys.stderr); sys.exit(2)

print("mas-entitlement-check (%s): %s" % (mode, "FAIL" if failed else "PASS"), file=sys.stderr if failed else sys.stdout)
sys.exit(1 if failed else 0)
PY
