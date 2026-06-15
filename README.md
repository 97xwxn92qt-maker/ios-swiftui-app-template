# iOS SwiftUI App Template

[![iOS Build (Unsigned IPA)](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/ios-build.yml/badge.svg)](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/ios-build.yml)
[![Release (Unsigned IPA)](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/release.yml/badge.svg)](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/release.yml)
[![Unit Tests](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/tests.yml/badge.svg)](https://github.com/hoangnd107/ios-swiftui-app-template/actions/workflows/tests.yml)

A starter for **native SwiftUI iOS apps** with a complete, free GitHub Actions
pipeline — from building the app all the way to publishing a release — **without
owning a Mac and without a paid Apple Developer account**.

- 🧱 **No `.xcodeproj` in git.** The Xcode project is generated from
  [`project.yml`](project.yml) with [XcodeGen](https://github.com/yonomi/XcodeGen),
  so there are no merge conflicts and no fragile project file.
- 📦 **Unsigned `.ipa` on every push.** The **iOS Build (Unsigned IPA)** action
  builds on a free `macos-latest` runner and uploads the IPA as an artifact —
  sideload it with [Sideloadly](https://sideloadly.io) / [AltStore](https://altstore.io)
  using a free Apple ID.
- 🚀 **Tag → Release.** Push `v1.2.3` and the **Release** action builds the IPA
  and publishes a GitHub Release with the `.ipa` attached and auto-generated notes.
- ✅ **Unit tests on the simulator** (on PRs / on demand) to conserve free minutes.
- 🌍 Builds offline with code signing disabled — nothing leaves the runner.

---

## The pipeline

```
                         ┌─────────────────────────────────────────┐
  push to main  ───────▶ │  iOS Build (Unsigned IPA)                │ ─▶ IPA artifact
  (or run manually)      │  xcodegen → xcodebuild (CODE_SIGNING=NO) │    (download & sideload)
                         │  → Payload/ → zip → *.ipa                │
                         └─────────────────────────────────────────┘

  push tag  v* ────────▶ │  Release (Unsigned IPA)                  │ ─▶ GitHub Release
                         │  same build  →  gh release create        │    with *.ipa attached
                         └─────────────────────────────────────────┘

  pull request ────────▶ │  Unit Tests (Simulator)                  │ ─▶ pass / fail
                         └─────────────────────────────────────────┘
```

All three workflows read the app/scheme name from `project.yml`'s `name:` field,
so **you never edit the workflows when you rename the app.**

---

## Quick start

1. Click **“Use this template” → Create a new repository** (or
   `gh repo create my-app --template hoangnd107/ios-swiftui-app-template`).
2. **Rename the app** (see below).
3. Push to `main`. The **iOS Build (Unsigned IPA)** action runs and uploads the
   `.ipa` under the run’s **Artifacts**.
4. When you’re ready to ship: `git tag v0.1.0 && git push origin v0.1.0` →
   the **Release** action publishes a GitHub Release with the IPA attached.

### Rename the app

Everything keys off `project.yml`:

1. `project.yml` → set `name:` to your app name (drives the scheme, `.xcodeproj`,
   product, module, and IPA filename).
2. `project.yml` → update `PRODUCT_BUNDLE_IDENTIFIER`, `bundleIdPrefix`, and
   `INFOPLIST_KEY_CFBundleDisplayName`.
3. Rename the test target `AppNameTests` (and its bundle id) to `<YourApp>Tests`.
4. Optionally rename `struct AppNameApp` in
   [`Sources/App/AppNameApp.swift`](Sources/App/AppNameApp.swift) — only `@main`
   matters, not the name.
5. Drop a real 1024×1024 PNG into
   `Resources/Assets.xcassets/AppIcon.appiconset/` (replace the placeholder).

---

## Project layout

```
.
├── .github/workflows/
│   ├── ios-build.yml      # iOS Build (Unsigned IPA) — push to main + manual
│   ├── release.yml        # Release — on tag v*, builds + publishes the IPA
│   └── tests.yml          # Unit Tests — PRs + manual (simulator)
├── Sources/
│   ├── App/AppNameApp.swift     # @main entry point
│   └── Features/ContentView.swift
├── Tests/
│   └── AppNameTests.swift       # XCTest unit tests
├── Resources/
│   └── Assets.xcassets/         # AppIcon + AccentColor
├── project.yml            # XcodeGen spec (single source of truth)
├── VERSION                # marketing version used in the IPA filename
├── .gitattributes         # forces LF endings (Windows-friendly)
└── .gitignore
```

---

## Local development (on a Mac)

```bash
brew install xcodegen
xcodegen generate          # creates AppName.xcodeproj from project.yml
open AppName.xcodeproj      # build & run in Xcode
```

On Windows/Linux you don’t need Xcode — edit the Swift files and let the GitHub
Actions runner build for you.

### Build an unsigned IPA locally (Mac)

```bash
xcodegen generate
xcodebuild -project AppName.xcodeproj -scheme AppName -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  clean build CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/AppName.app Payload/
zip -r AppName.ipa Payload
```

---

## Installing the IPA (free Apple ID)

1. Download the `.ipa` from the **Release** page, or from a build run’s
   **Artifacts**.
2. Open it in **Sideloadly** (or AltStore), sign in with a free Apple ID, and
   install to your iPhone.
3. On the device: **Settings → General → VPN & Device Management** → trust your
   developer profile.
4. Free Apple IDs expire after **7 days** — re-sideload to refresh.

> The IPA is **unsigned** on purpose; the sideloading tool signs it on-device
> with your Apple ID. This needs no paid Apple Developer Program membership.

---

## Notes

- `macos-latest` minutes are limited on free plans, so tests run only on PRs /
  on demand — the routine job is the IPA build on `main`. Adjust triggers in
  `.github/workflows/*.yml` to taste.
- Deployment target is **iOS 17.0**; change it in `project.yml`.
- The `Release` workflow needs `contents: write` permission (already set) and
  uses the built-in `GITHUB_TOKEN` — no secrets to configure.

## License

[MIT](LICENSE)
