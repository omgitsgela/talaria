# F-Droid submission

Status: **prepared, not submitted.** Nothing here is live on F-Droid yet.

F-Droid builds every app from source itself and signs the result with its own key. That means the
release key used for the GitHub releases is irrelevant to them, and their APK cannot update, or be
updated by, one from the GitHub Releases page.

## The recipe

[`com.ionfyre.talaria.yml`](com.ionfyre.talaria.yml) is the file that gets copied into
`metadata/` in a fork of [fdroiddata](https://gitlab.com/fdroid/fdroiddata). The application ID is
`com.ionfyre.talaria`, under a domain the project owns, which is what their policy advises.

Store listing text, screenshots and the per-version changelog live in `fastlane/metadata/android/en-US/`,
so the recipe needs no `Description` field.

## Compliance status against the inclusion policy

Checked against <https://f-droid.org/docs/Inclusion_Policy/> and
<https://f-droid.org/docs/Anti-Features/>.

| Requirement | Status |
|---|---|
| Free software licence | MIT, OSI and DFSG compatible. |
| No proprietary tracking, advertising or analytics; Google Play Services, Firebase and Crashlytics "strictly forbidden" | None present. The packaged APK carries no GMS, Firebase or Crashlytics entries, no `com.google.android.gms.version` metadata, and only optional androidx shared-library declarations. Permissions are minimal: INTERNET, ACCESS_NETWORK_STATE, POST_NOTIFICATIONS, FOREGROUND_SERVICE, FOREGROUND_SERVICE_SPECIAL_USE, WAKE_LOCK, VIBRATE. |
| 100 percent free build toolchain, no proprietary build tools (Oracle's JDK is named explicitly) | Builds with OpenJDK (Eclipse Temurin) 21, Gradle and the Android SDK, all free. `CONTRIBUTING.md` says so. |
| Prebuilt binaries only from trusted sources | No binaries are committed. The Flutter SDK and Android SDK binaries used are the ones the policy explicitly allows. |
| No API keys needed | None. The user supplies their own gateway URL and token. |
| No downloading of executable binaries without opt-in | The app never downloads or executes anything. |
| Distinct application ID | `com.ionfyre.talaria`, distinct from anything else in the repo, under a domain the project owns. |
| Actively maintained, functional, useful, unique | An original client, not a rebrand or a demo. |
| No undisclosed anti-features | None apply; see below. |

### Anti-features

None should be flagged, and two are worth arguing in the submission rather than leaving to be
inferred:

- **Not TetheredNet.** That flag applies to apps which depend on a service that is hard to replace,
  *unless* the app has a simple option to point at an alternative, publicly available, self-hostable
  server. Talaria accepts any gateway URL and Hermes is MIT licensed and self-hostable, so the
  carve-out applies directly.
- **Not Tracking.** The diagnostic report is assembled on the device and only moves when the user
  copies and pastes it. There is no crash reporting, no analytics, and no update check.

### Assets

The logo and the launcher icons derived from it were generated for this project and are released
under the same MIT licence as the code, which the README states. Their policy requires every asset
to carry a valid licence or be public domain.

## Submitting

1. Fork <https://gitlab.com/fdroid/fdroiddata>.
2. Copy `com.ionfyre.talaria.yml` into `metadata/`, with `versionName`, `versionCode`, `commit` and
   `CurrentVersion*` set for the release being submitted. The tag must exist and its build must
   produce those exact version values.
3. Open a merge request and be ready to answer questions. A person reviews each submission.

## Prerequisites still to satisfy

- **The repository has to be public** before their build can reach the source.
- **`srclibs: flutter@3.47.2`** must be usable by their builder, which clones
  `github.com/flutter/flutter` at that tag and drives `bin/flutter`. Flutter fetches engine
  artifacts and pub packages on first run, which depends on their build containers' network access.
  If the pinned version is not usable there, either adjust the pin or add the srclib in the same
  merge request. This can only be settled by an actual F-Droid build.
- **A crisp listing icon** is optional: F-Droid uses the APK's launcher icon, which tops out at
  192x192 here. Supplying a 512x512 PNG at `fastlane/metadata/android/en-US/images/icon.png` would
  look sharper in their client.

## Local sanity check

```sh
pip install fdroidserver
fdroid lint com.ionfyre.talaria.yml
fdroid build --verbose com.ionfyre.talaria -v 1.2.0
```

`fdroid build` needs the Flutter SDK on `PATH` and enough disk for a cold Flutter build.
