# Self-update sideload channel

Kotatsu already ships an in-app updater: it polls the GitHub Releases API of the repo
named in `app/src/main/res/values/constants.xml` (`github_updates_repo`), and when a
release has a higher version with an APK asset, it shows an **Update** button in the main
menu and in Settings → About. Tapping it downloads the APK and launches the installer.

This doc sets that machinery up to serve **your own** builds, so each time you fix a
manga source you publish a new APK and your phone offers it — no code changes to the
updater itself.

## How it fits together

```
fix parser in ../kotatsu-parsers   (composite build, see MEMORY / kotatsu-source-maintenance)
        │
        ▼
scripts/release-nightly.sh         builds a signed nightly APK + gh release create
        │
        ▼
GitHub release on YOUR fork        asset = Kotatsu-N<stamp>.apk
        │
        ▼
phone: Kotatsu checks on launch    Update button → download → install over existing app
```

## One-time setup

1. **Point the updater at your fork.** In `app/src/main/res/values/constants.xml`, set
   `github_updates_repo` to your `owner/repo` (replacing `KotatsuApp/Kotatsu`).

2. **Signing keystore.** A dedicated keystore was generated at
   `~/.android-keystores/kotatsu-sideload.jks` (password in
   `~/.android-keystores/.kotatsu-sideload.pass`). Its coordinates are in `local.properties`
   under the `sideload.*` keys. **Back this file up.** Every future update must be signed
   with the *same* key — Android refuses to install an update signed by a different key
   (it would force an uninstall, losing your library).

3. **Android SDK.** Install it and set `sdk.dir` in `local.properties` (Android Studio does
   this automatically, or `sdkmanager`). Required to build any APK.

4. **GitHub token.** Create a fine-grained Personal Access Token with `Contents: read and
   write` on `pcthien/Kotatsu`. Provide it to the script via either `export GITHUB_TOKEN=...`
   or a `github.token=...` line in `local.properties` (gitignored). The script talks to the
   GitHub REST API with `curl` — no `gh` install needed, and it uploads the APK with the
   exact `application/vnd.android.package-archive` content type the updater requires.

## Build type: `nightly` (why)

- Its `BUILD_TYPE` is `nightly`, so `AppUpdateRepository.isUpdateSupported()` returns true
  without touching the official-signature gate in `AppValidator` (that gate only blocks the
  `release` build type when signed by a non-official key).
- Its `applicationId` suffix `.nightly` means it installs **alongside** any official Kotatsu
  — no signature clash with an app you didn't build.
- Version is stamped as `N<minutes-since-2020>` (see `app/build.gradle`), which fits in an
  `Int` and increases every minute, so every build outranks the previous one and the updater
  always sees a fresh build as newer. (Plain date `N-yyyyMMdd` collided on same-day builds.)

## Per-fix release loop

```bash
# after fixing/verifying a parser in ../kotatsu-parsers
cd /Users/tiph/Code/Kotatsu
scripts/release-nightly.sh "Fixed TruyenQQ domain + search"
```

The script: computes the stamp, builds `:app:assembleNightly -PbuildStamp=<stamp>`, verifies
the APK is signed, and runs `gh release create N<stamp> ...` on the repo from `constants.xml`.
The release notes you pass become the changelog shown on the in-app update screen.

Then open Kotatsu on the phone. It checks for updates on launch; pull-to-refresh the main
screen or reopen the app to force a check.

## Gotchas

- **First install must be your build.** If the phone currently runs the official
  `org.koitharu.kotatsu`, your build has a different signature and cannot update over it.
  The `.nightly` package installs separately, so that is fine — but migrate your library via
  Settings → Backup if you want your data in the nightly app.
- **Asset MIME type.** The updater only accepts an asset whose GitHub `content_type` is
  `application/vnd.android.package-archive`. GitHub assigns this to `.apk` uploads; if a
  release ever fails to appear, confirm the asset type in the release API.
- **Keystore loss = dead channel.** Lose the keystore and you can no longer ship updates the
  installed app will accept. Back it up somewhere durable.
- **Stable vs unstable.** Nightly versions are treated as unstable by `VersionId`. The
  nightly build itself always accepts nightly updates; no `isUnstableUpdatesAllowed` toggle
  needed for the `.nightly` app.
