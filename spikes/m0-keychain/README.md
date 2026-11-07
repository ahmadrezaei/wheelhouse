# M0 keychain-sync spike (risk R1)

Question: is a **synchronizable** keychain item written on the iPhone in the shared group
`JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared` readable by a Mac binary signed with **Apple Development**
and a Mac development provisioning profile (and the reverse)?

The spike touches **one** item only: service `app.wheelhouse.m0-probe`, account `probe`, synchronizable.
Nothing else in the keychain is queried, listed or read. It holds a random token, a timestamp and the writer name.

Pieces:

- `spikes/m0-keychain/` is a standalone XcodeGen project (not part of the main `project.yml`). It builds the Mac app
  bundle `m0probe.app` (`com.ahmadrezaei.wheelhouse.mac.m0probe`, team JCZY58QP3L, automatic signing). It has no UI; you
  run its executable from a terminal. It must be an app bundle because the keychain-access-groups entitlement needs an
  embedded provisioning profile.
- `Wheelhouse/App/DebugKeychainProbe+iOS.swift` is a DEBUG-only hook in the iOS app: `-WHKeychainProbe write|read|delete`.
  The result is shown in an alert and logged (`WHKeychainProbe: ...` in the Xcode console). The file and its call are
  compiled out of Release builds.

## 0. One-time setup: register this Mac

The first signed build failed with: `Device "MacBook Pro" isn't registered in your developer account`.
Register the Mac, then rebuild:

- Find this Mac's provisioning UDID with `system_profiler SPHardwareDataType | grep Provisioning`.
- Either open `spikes/m0-keychain/M0Probe.xcodeproj` in Xcode, select the `m0probe` target, Signing & Capabilities,
  and click Register Device (needs an Admin or Account Holder role), or add the device at
  developer.apple.com, Certificates, Identifiers & Profiles, Devices.

## 1. Build and sign the Mac probe

```
cd spikes/m0-keychain
xcodegen generate --spec project.yml
xcodebuild build -project M0Probe.xcodeproj -scheme m0probe -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/wh-m0probe-dd -allowProvisioningUpdates
PROBE=/tmp/wh-m0probe-dd/Build/Products/Debug/m0probe.app/Contents/MacOS/m0probe
codesign -d --entitlements - /tmp/wh-m0probe-dd/Build/Products/Debug/m0probe.app   # shows keychain-access-groups
```

If you build outside `/tmp`, avoid `~/Documents` for the derived data path.

## 2. Direction A: iPhone writes, Mac reads

1. Make sure the iPhone and the Mac are signed in to the same Apple Account with **iCloud Keychain on** (Settings,
   Apple Account, iCloud, Passwords and Keychain, Sync this iPhone). Synchronizable items travel through iCloud Keychain.
2. In Xcode, open `Wheelhouse.xcodeproj`, choose the **Wheelhouse** scheme, Product, Scheme, Edit Scheme, Run,
   Arguments, and add the launch argument `-WHKeychainProbe write`. Select the iPhone (wired or wireless) as the destination and Run
   a **Debug** build (the default). An alert "Keychain probe: wrote token=... writer=ios" appears. Note the token.
3. Wait about 30 seconds to a minute for iCloud Keychain to sync (the Mac must be online and unlocked).
4. On the Mac:
   ```
   $PROBE read
   ```
   Pass: it prints the same token with `writer=ios`. Fail: `not found` (item did not arrive or the group is not
   visible) or an OSStatus (for example -34018 means the entitlement or profile is missing: re-run step 1).

## 3. Direction B: Mac writes, iPhone reads

1. On the Mac: `$PROBE write` and note the token.
2. Wait about a minute. In Xcode change the launch argument to `-WHKeychainProbe read` and Run on the iPhone again.
3. Pass: the alert shows the same token with `writer=mac`.

## 4. Clean up

```
$PROBE delete
```
Then run the iOS app once with `-WHKeychainProbe delete`, and remove the launch argument from the scheme afterwards.
Deleting a synchronizable item propagates to the other device; `read` on either side then reports `not found`.

## Safety notes

- The service and account are fixed (`app.wheelhouse.m0-probe` / `probe`) and every query also pins the access group
  and `kSecAttrSynchronizable = true`. The code contains no wildcard or list query.
- The hook is DEBUG only. To check a Release build: `nm` or `strings` on the Release binary must show neither
  `WHKeychainProbe` nor `m0-probe`.
- Reporting back: tell the engineer which direction passed and the exact error status if one failed.
