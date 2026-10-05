# MNtfs releases and Sparkle updates

Sparkle 2.9.6 is pinned through Swift Package Manager and linked only by the
host app. The FSKit extension, bundle identifiers, and Apple team stay the same
across updates. The menu provides **Check for Updates…** and automatic daily
checks. Installing is interactive: MNtfs pauses new disk operations and requires
all `mntfs` volumes to be ejected before replacing its file system extension.
It never force-unmounts a drive for an update. Background reminders appear in
the menu as **Update to <version>…**.

## One-time setup

The production feed is:

`https://maclifevn.github.io/mntfs/updates/appcast.xml`

The generated `dist/updates/` directory is hosted at that path using GitHub
Pages for `maclifevn/mntfs`, from the `gh-pages` branch and `/` directory.
Configure Pages once in the repository settings. The branch only contains the
appcast, release notes, and a download link. Archive downloads use the existing
repository's GitHub Releases. Keep the feed URL stable.

Resolve the package and its signing tools:

```sh
TASK_ROOT="$PWD"
xcodebuild -resolvePackageDependencies -project "$TASK_ROOT/FastNTFS.xcodeproj" \
  -scheme FastNTFS -clonedSourcePackagesDirPath "$TASK_ROOT/build/SourcePackages" \
  -packageCachePath "$TASK_ROOT/build/PackageCache" \
  -derivedDataPath "$TASK_ROOT/build/DerivedData"
```

An Ed25519 key was created in this Mac's login Keychain under account
`com.fastntfs.FastNTFS`. Only its public key is committed in
`Sources/App/Info.plist`. Do not generate a replacement key for every release,
reuse MFinder's private key, or export a private key into the repository.
Back up the signing Keychain securely. Another release Mac needs the same
signing key; loss of that key prevents existing installs trusting new updates.

To check the public key without exposing private material:

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.fastntfs.FastNTFS -p
```

The existing Developer ID certificate, FSKit Developer ID provisioning profile,
and App Store Connect notarization credentials are still required.

## Build a release

1. Increase `MARKETING_VERSION` and the integer `CURRENT_PROJECT_VERSION` for
   **both** targets in both configurations. Build numbers must be greater than
   every published build, even if the display version changes.
2. Add `release-notes/<version>.md` and run `./scripts/test.sh`.
3. Supply `ASC_KEY`, `ASC_KEY_ID`, and `ASC_ISSUER` through the environment.
   Alternatively set `MNTFS_NOTARY_PROFILE` to an existing `notarytool` Keychain
   profile for the same Apple team. Run the release script locally:

```sh
./scripts/release.sh 0.1.2 release-notes/0.1.2.md --bootstrap
# Later releases omit --bootstrap:
# ./scripts/release.sh 0.1.3 release-notes/0.1.3.md
```

`--bootstrap` is for the first feed only. A missing feed must return HTTP 404;
network errors, invalid signatures, and reused build numbers stop the release.
An existing feed is always verified before its entries or notes are reused.
Set `MNTFS_DIST_DIR=dist/test` to keep test packages separate from previous
release artifacts. The build is signed manually with Developer ID after
compilation, so it does not need an Apple Development provisioning profile.

The script builds and signs the app, FSKit extension, formatter, and all nested
Sparkle helpers; notarizes and staples the app; creates the final stapled ZIP
and notarized DMG; then generates the signed feed and release notes. It does
not upload anything. Output:

- `dist/MNtfs-<version>.dmg` for initial/manual installation.
- `dist/MNtfs-<version>.zip` for Sparkle.
- `dist/updates/appcast.xml` and `MNtfs-<version>.md` for Pages.

The ZIP, appcast, and notes have Ed25519 signatures. Validation checks the
embedded key, host/extension identifiers and versions, Developer ID signatures,
and stapled ticket. A tamper test must reject modified copies of all three
signed artifacts. Five full update entries are retained; deltas are disabled.
Scheduled checks use a one-day phased rollout; manual checks can find the new
release immediately.

## Publish in this order

1. Create GitHub release `v<version>` in `maclifevn/mntfs` and upload the exact
   generated DMG and ZIP. Never modify or re-compress the ZIP after signing.
2. Publish `dist/updates/` to the Pages `updates/` directory. Preserve older
   notes: clients with cached feeds may still reference them. Do not hand-edit
   a signed appcast or note file; regenerate signatures after any change.
   `./scripts/publish-update-feed.sh <version>` verifies the feed and the hosted
   ZIP's SHA-256 digest, then commits and pushes Pages files to `gh-pages`.
3. Check the live feed, notes, and enclosure URLs, then test **Check for
   Updates…** from an older Sparkle-enabled copy in `/Applications`. Confirm
   that a mounted `mntfs` volume blocks installation, eject it, retry, and
   verify the new app version and extension after relaunch.

Versions released before this integration have no updater. Users install the
first Sparkle-enabled release manually from its DMG once; subsequent releases
can update in the app.

If a Pages layout or release repository changes, update `SUFeedURL` before the
first bootstrap. `MNTFS_RELEASE_REPOSITORY` overrides the archive repository;
`MNTFS_CURRENT_FEED_URL` or `MNTFS_PREVIOUS_APPCAST` can supply a previous signed
feed during release recovery. `MNTFS_SPARKLE_BIN` locates the pinned tool bundle
if it lives elsewhere. `MNTFS_PREVIOUS_NOTES_DIR` can reuse previously generated
notes locally; their signatures are still verified. Changing the signer account
with `MNTFS_SPARKLE_ACCOUNT` still requires the same embedded public key.

## Local QA

Debug builds do not start Sparkle unless `MNTFS_ENABLE_UPDATES=1`. Only Debug
builds accept `MNTFS_UPDATE_FEED_URL` for a local test feed; signed feed and
archive verification remain enabled. Tests never launch the live volume manager
or operate on connected disks.

The standalone feed builder can test an ad-hoc-signed local archive with
`MNTFS_ALLOW_UNNOTARIZED_TEST_ARCHIVE=1`. This skips only Developer ID/notarization
validation, and prints a **TEST ONLY** marker; archive identity and all Ed25519
checks still run. `release.sh` explicitly removes this override. Never publish
an archive or feed from that QA path.

Reference: [Sparkle documentation](https://sparkle-project.org/documentation/)
and [gentle reminders for background apps](https://sparkle-project.org/documentation/gentle-reminders/).
