# F-Droid preparation

Status: **prepared, not submitted.** Nothing here is live on F-Droid yet.

[F-Droid](https://f-droid.org) builds every app from source itself and signs the result with
its own key. That means:

- The signing key in this repository is irrelevant to F-Droid. They do not accept prebuilt
  APKs, and they will not use the one attached to our GitHub releases.
- Users who install from F-Droid get an APK signed by F-Droid's key. It cannot be updated by,
  or update, an APK installed from the GitHub release, because Android ties updates to the
  signing key. Pick one source per device.

## What has to be true before submitting

| Requirement | State |
|---|---|
| Source is publicly reachable | The repository must be public. It is private until the first review pass is finished. |
| Open-source dependencies only | Yes: MIT, BSD and Apache-2.0 packages, no proprietary or tracking SDKs. |
| No prebuilt binaries in the tree | Yes: build outputs, `.dart_tool/` and APKs are git-ignored. |
| A tagged release whose commit builds from source | Yes, if `flutter build apk --release` succeeds from the tag. |
| versionName/versionCode in the recipe match the built APK | Yes, see the `Builds:` entry. |

## Submitting

1. Fork <https://gitlab.com/fdroid/fdroiddata>.
2. Copy `com.talaria.talaria.yml` from this directory to `metadata/` in the fork, updating
   `versionName`, `versionCode`, `commit` and `CurrentVersion*` for the release being submitted.
3. Open a merge request. F-Droid's builders will run the recipe; `fdroid lint` and their build
   log will surface anything wrong.
4. If their build fails, the fix belongs in the recipe (usually the Flutter version pin or a
   dependency that needs network access) or in this repository.

Note that the built APK lands in F-Droid's own repository index. Their `AutoUpdateMode: Version`
plus `UpdateCheckMode: Tags` will pick up future releases automatically, which is why each public
release needs its own version name and tag rather than only a new build code.

## Known unknowns

These can only be settled by an actual F-Droid build, so treat the recipe as a starting point:

- **Flutter toolchain in their build environment.** `srclibs: flutter@3.47.2` clones
  `github.com/flutter/flutter` at that tag and drives `bin/flutter` directly. The Flutter tool
  downloads engine artifacts and pub packages on first run, which depends on the network access
  their build containers grant. If the pinned version is not usable there, either adjust the pin
  or add the srclib in the same merge request.
- **Dependency freshness.** `pubspec.lock` is committed, so the build resolves the same package
  versions that we do. If a package version has since been retracted, re-pin before submitting.
- **Category and anti-feature choices** are the maintainers' call. `Internet` plus `Development`
  is our reading of the app; no anti-features are declared, since the app talks only to the
  gateway the user configures and contains no tracking.

## Local sanity check

The recipe can be dry-run locally, which validates the YAML and the build steps without a full
F-Droid checkout:

```sh
pip install fdroidserver
fdroid lint com.talaria.talaria.yml     # metadata sanity
fdroid build --verbose com.talaria.talaria -v 1.1.1
```

`fdroid build` needs the Flutter SDK on `PATH` and enough disk for a cold Flutter build.
