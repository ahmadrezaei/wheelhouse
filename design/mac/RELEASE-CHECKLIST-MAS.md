# Wheelhouse for Mac (App Store): release checklist

Owner steps, in order. The pipeline is `scripts/release-mac-appstore.sh`; the plan is `design/mac/MAS-EDITION.md` (section 9 overrides earlier sections). The GitHub edition's release (`scripts/release-mac.sh`) is a separate flow and is not touched.

**Safety first.** A Distribution build has the development safety gate off and carries the shared iCloud keychain group `JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared`, which is synced from the iPhone and may hold production clusters. Never launch an archive, an exported app or a TestFlight build on your own macOS user. Use the separate test user (step 8).

## One-time setup

1. **Add the macOS platform to the App Store record.** App Store Connect > Apps > Wheelhouse (app 6831379262) > add the macOS platform. The bundle ID is `com.ahmadrezaei.wheelhouse`, the iOS one: macOS uses it as a universal-purchase platform, so check that the name and primary language carry over.
2. **Mac Installer Distribution certificate.** The Mac App Store package is signed with Apple Distribution plus Mac Installer Distribution. In Xcode > Settings > Accounts > Manage Certificates, check both exist for team JCZY58QP3L. With cloud-managed signing (`-allowProvisioningUpdates`) Xcode creates and manages them during the export; if the export fails with "no signing certificate Mac Installer Distribution", create it there or in the developer portal (Certificates > + > Mac Installer Distribution).
3. **Provisioning profiles.** Mac App Store profiles for `com.ahmadrezaei.wheelhouse` and `com.ahmadrezaei.wheelhouse.widgets`. Automatic signing creates them on the first archive and export. Both must list the iCloud keychain sharing group and the app group (the keychain group needs the app's profile).
4. **App group.** `JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas` is a team-prefixed macOS app group (the portal only registers `group.`-style IDs), so there is nothing to register. Confirm the Mac App Store profiles from step 3 cover it (check the profile's application-groups after the first export). Development builds used `.mas.debug`, which the wildcard development profile covered.
5. **Export compliance.** The app sets `ITSAppUsesNonExemptEncryption = false`. If App Store Connect still asks, answer that the app uses only the system's TLS.

## First upload

6. From a clean `main` that equals `origin/main`:
   ```
   scripts/release-mac-appstore.sh 1.0.0 <build>        # <build> must exceed the last mas-v* tag's build
   ```
   Use `--no-upload` first: it stops after the export to `.build/mas/export` and the check of the exported app. **Never open the exported `.pkg` on your own user** (it installs a Distribution build). The script runs the `--project` lint, the suites, the archive, `scripts/mas-entitlement-check.sh` on the archived app, an export to a folder and the same check on the app inside that package (strict: no `get-task-allow`, the exact App Store profile), then asks you to type the version, uploads and creates the local tag `mas-v<version>-<build>`. Push the tag yourself afterwards. On the first real export, if the check names an entitlement that Distribution signing injects from the profile, decide whether it is legitimate before allowing it in the script.
7. Wait for App Store Connect to finish processing, then add the build to an internal TestFlight group.

## On the TestFlight build

8. **Install on a separate macOS user** (one with no `~/.kube`, no iCloud data). Never on the main user.
9. **Gate OID.** Run `codesign --verify -R='anchor apple generic and identifier "com.ahmadrezaei.wheelhouse" and certificate leaf[field.1.2.840.113635.100.6.1.9] exists' /Applications/Wheelhouse.app && echo MAS-signed` (the Mac App Store leaf OID `1.2.840.113635.100.6.1.9`; the same requirement the app evaluates). Plain `codesign -d -r-` is not a valid test: its default requirement lists the OID as an alternative. If the command fails, the `DevSafety` gate stays on and the app refuses to read real data: stop and report it.
10. **Spike owner checks (plan section 9):**
    - A. The open-panel grant, relaunch and stale-rename flow: grant a folder, relaunch, rename the folder, relaunch, check the app resolves or asks again (about 3 minutes).
    - B. The login item on the TestFlight build (`SMAppService.mainApp` register, reboot or log out and in).
    - C. Delete `~/Library/Containers/com.ahmadrezaei.wheelhouse.masspike` and `~/Library/Group Containers/JCZY58QP3L.com.ahmadrezaei.wheelhouse.masspike` (test data of the spike, the automated shell can't).
    - D. A widget tap with both editions installed: the tap must open the edition that owns the widget (the MAS edition uses `wheelhouse-mas:`).
    Also on this build: two keychain groups plus `.shared` synchronizable items in the sandbox, the "Grant access to your .kube folder" flow, a `.minikube` "Needs access" prompt, an exec-plugin context showing the edition badge, and Save panel export.

## Store listing and submission

11. **Review cluster.** Prepare a cluster for App Review that works without credentials plugins (token or client certificate kubeconfig), reachable from the review network, and put the kubeconfig and steps in the review notes (`docs/AppReviewNotes.md`).
12. **Screenshots.** macOS screenshots at an accepted size (for example 2880 x 1800) of the features this edition keeps; none of the removed ones (terminal, Landfall, Beacon, rigging).
13. **Age rating** questionnaire, privacy answers (the app collects no data), category Developer Tools, support and privacy URLs, the "what is different from the GitHub edition" page `https://ahmadrezaei.github.io/wheelhouse/mac/editions.html` live.
14. **Submit for review.** Pick the processed build, fill the review notes, submit.

## If something fails

- `mas-entitlement-check.sh` names the entitlement, key or file that is wrong; do not upload around it. Fix the source (never loosen the script) and use a higher build number.
- A rejected or failed upload still consumed the build number: the next run needs a higher one.
- Delete `.build/mas` after a release; the archive holds a Distribution build.
