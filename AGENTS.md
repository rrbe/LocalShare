## Project

LocalShare is a native single-window macOS app written in Swift / SwiftUI. A user chooses files or folders, the window shows a QR code, and phones on the same Wi-Fi can browse the share read-only in a browser. Guest upload and Text Transfer are optional; the default is read-only.

The central engineering rule is **no package-external runtime dylibs**. System frameworks are fine. Pure Swift dependencies such as Swifter are built from SPM source into the binary. Binary frameworks, currently Sparkle, are allowed only when referenced via `@rpath`, bundled inside `.app/Contents/Frameworks/`, signed with the app, and verified by the dependency gate. Absolute package-external dylib paths such as `/opt/homebrew` and `/usr/local` are forbidden.

Related documents:

- Architecture: `docs/ARCHITECTURE.md`
- Visual design system: `DESIGN.md`

## Common Commands

```bash
swift build                      # Debug build; first run fetches Swifter
swift build -c release           # Release build
swift test                       # XCTest unit tests for pure functions
./build.sh                       # Release build -> assemble .app -> ad-hoc sign -> dist/LocalShare.app
open "dist/LocalShare.app"       # Local GUI smoke test

# Headless end-to-end test for server behavior
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"

# CLI paths; after CLI/HeadlessServer changes, also retest release because of the documented -O compiler trap
.build/debug/LocalShare --headless /path/a.html /path/dir
.build/debug/LocalShare a.html b.pdf
ln -s "$PWD/dist/LocalShare.app/Contents/MacOS/LocalShare" /tmp/localshare
/tmp/localshare --version

# Dependency rule check: after filtering system libraries, all remaining deps must be bundled @rpath frameworks
otool -L "dist/LocalShare.app/Contents/MacOS/LocalShare" | grep -v "/usr/lib/\|/System/Library/"
# Expected: only @rpath/Sparkle.framework/...; Sparkle.framework must exist in dist/LocalShare.app/Contents/Frameworks
```

Tests have two layers:

- `swift test`: XCTest coverage for pure functions such as `resolveWithinRoot`, `sanitizeFileName`, `Share.makeItems`, `availableURL`, i18n, and text handling.
- `tools/smoke-*.sh` / `smoke-*.cjs`: headless curl smoke tests for token auth and 302 cleanup, traversal blocking, single-file isolation, Chinese/space/percent filename decoding, multi-share virtual roots, upload defanging, interface binding, Markdown link sanitation, Accept-Language routing, and Text Transfer.

CI runs both layers on every PR and `master` push. `release.yml` only handles releases. Requirements: macOS 13+ and a Swift toolchain.

## Commit Messages

Use Conventional Commits and preferably write messages in English:

```text
<type>: <summary>
```

Allowed types: `feat` / `fix` / `refactor` / `chore` / `docs` / `test` / `perf` / `style`.

Use an imperative, lowercase summary under 72 characters, for example:

```text
fix: prevent stale token from reading new share
```

## Architecture Notes

This section is only a navigation map. Full request flow, XSS hardening, lifecycle, CLI, and headless details live in `docs/ARCHITECTURE.md`.

`App.swift` uses `@main enum EntryPoint` with three dispatch layers:

1. `LS_HEADLESS=1` runs `HeadlessServer`.
2. `CLI.parse` handles argv for `localshare <paths>...` and `--headless`.
3. Everything else starts `LocalShareApp`.

All three paths share one `FileServer`, which keeps request logic unified. GUI CLI forwarding uses `NSWorkspace.open(urls, withApplicationAt:)`; `AppDelegate.application(_:open:)` receives paths and hot-swaps `AppState.setShared`. If open events arrive before `AppState` exists, they are buffered in `pendingOpenURLs`.

`AppState` is the `@MainActor ObservableObject` and single source of truth. It owns `FileServer`, network candidates, and derived state such as `primaryURL` and `qrImage`. File shares are represented by `sharedItems: [URL]`: empty, single, or multiple. Cold launch does not automatically replay the previous share; Recent Shares offers manual restart. Closing the window does not quit, so the process and server keep running.

`FileServer` handles all requests through one Swifter middleware closure. It supports:

- token auth through `?t=` or cookie `ls_token`; browser navigations authenticated by query receive a cookie and 302 to a clean URL
- immediate token rotation on `setShared` / `stop`, invalidating old links and cookies
- online presence tracking by client IP with best-effort device-name lookup
- single-file, single-folder, and multi-share virtual-root routing
- traversal protection using decoded paths, standardized file URLs, and resolved symlinks
- directory listing, `index.html` serving, and 64 KB chunked file streaming
- Markdown / JSON / CSV preview shells at the same URL as the original file, with `?raw=1` and curl returning raw content
- guest upload for single-folder shares, guarded by traversal checks, filename sanitation, collision suffixing, atomic rename, 500 MB limit, executable-document defanging, `nosniff`, and quarantine metadata
- optional binding to the selected IPv4 interface when "current network only" is enabled

Utility modules have narrow responsibilities: `NetworkInfo`, `QRCode`, `Token`, `Mime`, `DirectoryListing`, `PreviewPage`, `MarkdownViewer`, `JsonViewer`, `CsvViewer`, `MarkedJS`, `Lang`, `L`, and `LStr`. i18n strings are compiled into the binary; the native app follows `AppState.langPref`, while the web UI is selected per request from `Accept-Language`.

`Updater.swift` wraps Sparkle. `UpdaterController` is constructed only by the GUI path; headless paths never touch Sparkle. Configuration lives in `bundle/Info.plist`. If `SUPublicEDKey` is still the placeholder, the updater does not start.

## Release and Versioning

The version is defined by git tags: `vX.Y.Z` on `master` tip. `bundle/Info.plist` contains placeholder values; CI overwrites `CFBundleShortVersionString` from the tag and `CFBundleVersion` from the run number. Do not edit `Info.plist` just to release a version.

When updating changelogs, update both `CHANGELOG.md` and `CHANGELOG_CN.md` in the same change so the English and Chinese histories stay aligned.

Release flow:

1. Merge all changes to `master`.
2. Write changelog bullets into an annotated tag note: `git tag -a vX.Y.Z -F notes.md`.
3. Push the tag.
4. `.github/workflows/release.yml` builds universal binaries, runs the dependency gate, creates the DMG, creates the GitHub Release, signs the DMG for Sparkle, and uploads `appcast.xml` as a Release asset.

`appcast.xml` is not committed. Sparkle feed URL is `https://github.com/rrbe/LocalShare/releases/latest/download/appcast.xml`, which always points to the latest release asset. Release notes should be user-facing `-` bullets in English, with no `#` heading because `git tag` treats those as comments.

## Cross-File Constraints

- **No package-external dylibs**: after adding or changing dependencies, run the `otool` check and confirm bundled frameworks exist in `Contents/Frameworks`.
- **Swifter 1.5.0 path double-encoding bug**: `req.path` still contains one percent-encoded layer before filesystem resolution. Decode with `removingPercentEncoding`; this is required for spaces, Chinese filenames, and encoded traversal attempts.
- **Traversal guard**: after joining paths, use `standardizedFileURL.resolvingSymlinksInPath`; the result must be equal to `rootPath` or have `rootPath + "/"` as prefix. Retest `../`, `%2e%2e`, and `..%2f` after changing this area.
- **Threading model**: Swifter callbacks run on socket threads, while `AppState` is `@MainActor`. Shared mutable server state is protected by one `NSLock`: `share`, `token`, `uploadEnabled`, `lastSeen`, `nameCache`, and `nameLookupInFlight`.
- **Share changes do not restart the server** when the port is unchanged, but they rotate tokens immediately. Change the key before changing content.
- **`.raw` has no keep-alive and unknown body length**, so file responses must write `Content-Length`.
- **Remote mount prefix**: generated HTML must use relative navigation/heartbeat endpoints so it works under both `/`
  and `/share/<token>/`; remote requests must carry the registered `share_id`, and the Client must reject stale IDs
  before forwarding to `FileServer`.

## Design Constraint

Prefer communicating through the design language over adding explanatory text. When text is necessary, keep it short, common, and natural.
