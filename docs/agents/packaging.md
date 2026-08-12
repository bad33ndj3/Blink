# Packaging & Releases

## Verifying a change

`swift build` alone does not update a running `dist/Blink.app` or `/Applications/Blink.app` — the packaged binary is a separate copy. Before showing a UI or behavior change as done:

```
pkill -f "dist/Blink.app/Contents/MacOS/Blink"
zsh scripts/package-app.sh
open dist/Blink.app
```

## Cutting a release

`Resources/Info.plist`'s `CFBundleShortVersionString` and the git tag (`vX.Y.Z`) must move together in the same commit. `AppUpdater` compares the two directly, and `.github/workflows/release.yml` publishes whatever `scripts/make-dmg.sh` builds at that tag's checkout — a tag pushed without the matching plist bump ships a release whose in-app version disagrees with its own tag.

Order: bump `CFBundleShortVersionString` → commit → push to `main` → `git tag -a vX.Y.Z -m "..."` → `git push origin vX.Y.Z`. CI builds and publishes the DMG from there.

## SPM resource gotchas

- Asset catalogs (`.xcassets`) are not compiled into `Assets.car` under SPM for this target — named-image lookups against them silently fail. Use loose image files (`.png`/`.jpg`) as SPM resources, loaded via `Bundle(...).url(forResource:withExtension:)` + `NSImage(contentsOf:)`.
- `Bundle.module`'s generated accessor resolves relative to `Bundle.main.bundleURL` — the `.app` root, not `Contents/Resources`. `scripts/package-app.sh` places the resource bundle in the conventional `Contents/Resources` location, so lookups must check `Bundle.main.resourceURL` first and fall back to `Bundle.module`.
- Nested resource bundles must live inside `Contents/Resources`, not at the bundle root — `codesign` fails with "unsealed contents present in the bundle root" otherwise.
- The app icon is a plain `.icns` at `Resources/AppIcon.icns` referenced via `CFBundleIconFile`, not an `.xcassets` app icon set — same reason as above, asset catalogs don't compile under SPM for this target. `scripts/package-app.sh` copies it into `Contents/Resources`.

## Performance: cache decoded assets

SwiftUI `body` re-evaluates on every observed state change — including the break overlay's 1-second countdown tick. Expensive one-time work referenced from `body` (image decode, file I/O) belongs in a `static let`, not a computed property, or it silently re-runs every tick and janks the UI.
