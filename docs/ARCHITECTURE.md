# LocalShare Architecture

> Native single-window macOS app: choose a folder, show a QR code, and let phones on the same Wi-Fi browse it read-only in a browser. Guest upload and Text Transfer can be enabled when needed; the default is read-only.

This is the **current architecture reference**: core constraints, project structure, important design decisions, and implementation notes for anyone continuing work after `git pull`. Related documents: visual design specification in `DESIGN.md`; release/version workflow in `CLAUDE.md`.

---

## 0. Core Rule: No External Package Dylibs

The typical crash this project avoids is an arm64 binary that **misses a dynamic library at runtime** because it links to a package-external `.dylib`, for example under `/opt/homebrew/...`, which is absent on another Mac. The rule means: **the app must not depend on libraries that are missing on a clean machine**.

- System frameworks are allowed. Pure Swift third-party dependencies, such as Swifter, are built from SPM source and statically included in the executable.
- **Relaxed since 0.3**: Sparkle, required for automatic updates, is distributed only as a binary framework containing a dynamic library, XPC service, and helper app. It is allowed only when referenced through `@rpath` and bundled inside `.app/Contents/Frameworks/`. It travels with the app and is self-contained, so it avoids the external-library failure mode.
- **Acceptance rule**: any dylib outside the `.app` bundle is forbidden. Absolute paths such as `/opt/homebrew` and `/usr/local` are never allowed. Only `@rpath` references are accepted, and the corresponding framework must exist in `Contents/Frameworks/`. `build.sh` and CI both enforce this by filtering system libraries and checking that all remaining dependencies are bundled frameworks.

---

## 1. Locked Design Decisions

| Area | Decision |
|---|---|
| Platform | macOS only, native `.app`, Apple Silicon first |
| Network | Same Wi-Fi / LAN only; no tunnel, public endpoint, or account |
| Stack | Swift / SwiftUI, system frameworks only, no external package dylib risk |
| HTTP server | Swifter from SPM source, primarily read-only static serving |
| Share model | Three shapes: single folder -> mobile-friendly directory listing, serving `index.html` directly when present; single file -> scan opens the file and sibling files are not exposed; multiple files/folders -> synthetic virtual root listing selected items, with the first path segment mapped to a real URL. All shapes block directory traversal, each item using its own root |
| Auth | Every share action creates a random token embedded in the QR URL as `?t=...`; first visit validates it and sets a session cookie; later resources are allowed by cookie. Changing or stopping a share rotates the token immediately, invalidating old links, cookies, and QR codes. Anyone guessing `IP:port` receives 403 |
| Protocol | Plain HTTP. Threat model: block people who only guess the address; do not protect against same-network sniffing or forwarded links. Token rotation limits forwarded-link lifetime to the current share. Self-signed TLS would turn scan-to-use into certificate warnings, so it is intentionally not used |
| QR code | Raw LAN IP selected from network candidates; generated with CoreImage `CIQRCodeGenerator`; no third-party QR dependency. Window also shows a `.local` fallback and copyable URL |
| GUI | Single window: functional home screen with drag/drop and picker, Text Transfer entry, and Recent Shares; file ticket, Text Transfer, Settings, and History are secondary pages with back navigation |
| Lifecycle | Cold launch does **not** replay the last share. The app starts on the home screen; the last share remains in Recent Shares for one-click restart. Closing the window does not quit; process and server continue running, and menu bar activation restores the previous screen. Ports are selected automatically; service stops on app quit |
| Distribution | Xcode ad-hoc signing. The first Gatekeeper approval is handled manually and then remembered by macOS |
| Automatic updates | Sparkle bundled through `@rpath`; background checks, user-confirmed update prompt, EdDSA trust chain independent of ad-hoc code signing and notarization |
| Sandbox | App Sandbox is off because this is internally distributed and must read arbitrary user-selected folders |
| Internationalization | Simplified Chinese + English strings compiled into the binary, not resource bundles. Two language domains are independent: native app follows Settings; web UI is selected per request from browser `Accept-Language` |

---

## 2. Project Structure

```text
LocalShare/
  Package.swift            # swift-tools-version:5.9; Swift 5 language mode for relaxed concurrency checks
  Package.resolved         # Swifter pinned at 1.5.0
  build.sh                 # swift build -c release -> assemble .app -> ad-hoc sign -> dist/
  bundle/Info.plist        # Static .app Info.plist template: Sparkle feed/key and version placeholders
  README.md / README_CN.md # English default + Chinese
  CLAUDE.md                # Claude Code working guide; loaded from repo root
  DESIGN.md                # Visual design spec; source references use section numbers from this file
  docs/
    ARCHITECTURE.md        # This file
    images/                # README screenshots
  Sources/LocalShare/
    App.swift              # @main EntryPoint: GUI / headless / CLI dispatch; LocalShareApp and AppDelegate
    AppState.swift         # @MainActor ObservableObject; single source of truth for shares, text, server, network, presence, persistence
    ContentView.swift      # Single-window SwiftUI composition: home + secondary pages
    Components.swift       # Ticket-style UI component library; receives Theme explicitly
    Theme.swift            # Color/theme generation for light/dark mode and selectable accent
    FileServer.swift       # Swifter wrapper: token middleware, traversal guard, directory/file/multi-share, upload, presence
    Permission.swift       # Permission model and PermSummary copy derivation
    FileType.swift         # Extension classification, preview types, executable-document defang list
    DirectoryListing.swift # Mobile-friendly directory listing HTML; segment-encoded hrefs, hidden files omitted
    PreviewPage.swift      # Shared preview shell using same URL as the file
    MarkdownViewer / JsonViewer / CsvViewer  # Preview cards; Markdown uses vendored marked; JSON/CSV are zero-dependency
    MarkedJS.swift         # Vendored marked compiled as a Swift string constant
    SendTextPage / TextViewer  # Text Transfer: phone -> Mac send page and text preview shell
    NetworkInfo.swift      # getifaddrs -> private IPv4 candidates and .local hostname
    QRCode.swift           # CoreImage QR -> NSImage, plus terminal ANSI output
    Token.swift / Mime.swift   # Random token and extension -> MIME mapping with charset=utf-8 for text
    Lang.swift             # i18n string tables compiled into the binary: L / LStr / i18nJSON
    HeadlessServer.swift   # LS_HEADLESS=1 mode and CLI foreground mode
    CLI.swift / CLIInstaller.swift  # argv parsing, GUI forwarding, symlink installer
    Updater.swift          # Sparkle automatic update wrapper, constructed only in GUI path
  Tests/LocalShareTests/   # XCTest pure-function tests: traversal, filename sanitation, multi-share keys, i18n, text
  tools/                   # Headless + curl smoke scripts: traversal, filenames, multiselect, upload defang, token 302, md links, language, text
```

`@main enum EntryPoint` has three dispatch layers: `LS_HEADLESS=1` -> `HeadlessServer`; matching `CLI.parse` argv -> `CLI.run`; otherwise `LocalShareApp` (SwiftUI). All three paths share the same `FileServer`, which keeps request logic from forking.

---

## 3. Key Implementation Notes

### Swifter 1.5.0 API and Encoding Trap

- All request handling lives in **one middleware closure** that always returns a response and bypasses the router. `HttpResponse.raw(code, reason, headers, writer)` controls status, custom headers, and streamed file writes.
- **Double-encoded path bug**: Swifter's `HttpParser` leaves one layer of percent encoding in `request.path` before filesystem resolution. Always call `removingPercentEncoding`. Plain ASCII paths like `a.html` work either way, but `b%20c.txt` and Chinese filenames 404 without decoding. Traversal checks also use the decoded path, so `%2e%2e` is blocked.
- `.raw` has unknown body length and closes after send with no keep-alive. File responses therefore set **`Content-Length` explicitly**, which also gives phones progress information. This is sufficient for LAN static serving.

### FileServer Request Flow

1. **Token auth**: allow requests when either `?t=` or cookie `ls_token` equals the current token. Each request snapshots the token once so rotation cannot mix states. When `?t=` grants access, send `Set-Cookie: ls_token=...; HttpOnly`. Browser navigations with `Accept: text/html` then **302** to the clean URL without `?t=` so tokens do not stay in address bars or history. curl and `*/*` subresource requests do not trigger the redirect.
2. **Traversal guard**: `decoded -> strip leading / -> append to root -> standardizedFileURL.resolvingSymlinksInPath`. The result must equal the root path or have `root + "/"` as prefix; otherwise return 403. `standardizedFileURL` removes `..`; encoded dot-dot is blocked because decoding happens before normalization.
3. **Directories**: path without trailing slash gets 301 so relative resources resolve; `index.html` is served directly when present; otherwise `DirectoryListing` renders the listing with segment-encoded absolute hrefs, hidden files omitted, and a fixed parent row outside the root.
4. **Files**: MIME is inferred by extension, text types get `charset=utf-8`, and `FileHandle` streams in 64 KB chunks. Exception: browser navigation to `.md` / `.json` / `.csv` returns a preview shell at the **same URL as the file**, so relative references resolve through normal serving. curl, `?raw=1`, and `*/*` receive raw file content.

Single-folder serving extracts steps 2-4 into `serveTree(rootURL:relPath:...)`. **Single-file** shares return only that file. **Multi-share** uses `Share.multiple([Item])`, where `makeItems` uses `lastPathComponent` as key and appends `-2` for collisions. Empty path returns the virtual-root listing; otherwise the first path segment is mapped to a real URL. Unknown keys and subpaths under file items return 404. Each item has an independent traversal root.

### Web XSS Hardening

Served files run under the share origin (`http://host:port`), so HTML/SVG can execute same-origin scripts. Defenses:

1. **Guest-upload defang**: `sanitizeFileName` appends `.txt` to executable document extensions such as html, htm, xhtml, svg, svgz, and mht. This blocks the stored-XSS path where a guest uploads `index.html` into a folder and future visitors execute it by entering the directory. It applies **only to uploads**; a sharer-owned static site already on disk, including `index.html`, is still served normally for directory shares.
2. **Global `X-Content-Type-Options: nosniff`**: defense in depth; correctly declared files keep working.
3. **Markdown link/image protocol allowlist** in `MarkdownViewer.rendererConfig`: `.md` previews are not upload-defanged, so marked's `link` and `image` renderers are overridden. Allowed protocols are safe web/mail/phone schemes, `data:` for images, and relative/hash URLs. Two details matter: decode HTML entities before checking to block `&#106;avascript:`, and remove code points <= 32 after decoding to block `java<TAB>script:`. A colon counts as a protocol only before any `/ ? #`. `tools/smoke-md-link-sanitize.cjs` tests this with the real vendored marked build.

Related hardening: token 302 cleanup; uploaded files receive `com.apple.quarantine` so Gatekeeper runs if the sharer later opens them. Regression script: `tools/smoke-upload-defang.sh`.

### Guest Upload

`Permission.add` controls upload. It shares the same lock as `share`, can be enabled only for single-folder shares, and resets to read-only when the share changes. Multipart POST writes into the current browser directory after the same traversal check. Filenames are reduced to the last path segment, sanitized, collision-suffixed with `-2`, written through a temp file, then atomically renamed. Per-file limit is 500 MB with 413. **Swifter reads the whole body before middleware runs**, so the limit can only reject after the read; chunked upload is left for future work. `onUpload` runs on the socket thread and hops to `MainActor` for the in-app "new received" card.

### Online Presence

After auth, requests record `lastSeen` by client IP. A 45-second window counts as "N people browsing". Device-name reverse lookup runs best-effort in the background through `getnameinfo`, with `nameCache` and `nameLookupInFlight` protected by the server lock and cleared on token rotation. `/ls/ping` is a reserved heartbeat path handled before share content; listing pages call it every 15 seconds and it returns only counts, not device names. The GUI polls every 2 seconds through `AppState`, uses a named lead visitor when known, falls back to "N people browsing", hides IPs from the summary, and shows details in a popover.

### Current-Network-Only Binding

When `FileServer.listenAddress` is non-nil, Swifter binds only that IPv4 address through `listenAddressIPv4`. `AppState.bindSelectedOnly` drives it. Changing interface or switch state rebinds without rotating the token. If the selected IP disappears, the app falls back to all interfaces. Invalid `inet_pton` input throws instead of silently binding all interfaces. Default `nil` means `0.0.0.0`.

### AppState and Lifecycle

- Single source of truth is `sharedItems: [URL]`: empty, single, or multiple. Derived values include `isMultiple`, `isEmpty`, and convenience `sharedURL`.
- **Cold launch does not restore sharing**. `init` does not read the last share back into `sharedItems`, and no file service starts automatically. Quietly serving a folder on LAN after opening the app would be unsafe. The last share remains available in Recent Shares (`RecentShare.paths`) for manual restart. Text inbox can auto-start only when explicitly enabled.
- Closing the window does **not** quit. The process and service continue; `@StateObject` is created once per process, so reactivating the app returns to the previous screen.
- Port preference order is `[8080, 8000, 8888, 9000]`; if all fail, choose a random high port.
- **Changing a share does not restart the server** when the port is unchanged. The lock updates `share` and `token`, with the key changed before the content to prevent an old token from briefly reading the new share.

### Screen Routing

`Screen` enum: `.share` home, `.file` ticket, `.text` Text Transfer, `.settings`, and `.history`. File ticket and Text Transfer are secondary pages with shared header shape: back button, title, settings gear. The LocalShare brand appears only on the home screen. `ActiveShareBanner` appears on the home screen while file sharing continues in the background and lets users return to the ticket in one action.

### App Entry, Headless Mode, and CLI

- `localshare a.html b.pdf` forwards paths to the GUI with `NSWorkspace.open(urls, withApplicationAt:)`; a running instance is reused and hot-swaps the share without restarting the server. `--headless` runs a foreground server in the current process and prints terminal QR output with `QRCode.ansi`.
- The installed `localshare` command is a **symlink** to the main binary inside the app bundle. dyld resolves `@executable_path` after realpath, so bundled Sparkle still loads. But CLI code **must not use `Bundle.main`** to locate the `.app`; it resolves `_NSGetExecutablePath`, follows symlinks, then walks up three levels.
- **Release compiler trap**: with `-O`, the chain "optional `in_port_t` payload inside enum -> construct `[in_port_t]` inside function -> pass to `FileServer.start`" can miscompile into a bad array pointer. Debug works; release crashes. Workaround: `runForeground` accepts concrete `preferredPorts: [in_port_t]`, and callers unwrap the optional. Any CLI or `HeadlessServer` change must be smoke-tested in release with `--headless`.

### Automatic Updates with Sparkle

- Sparkle is imported as an SPM `binaryTarget`. `build.sh` uses `ditto` to copy `Sparkle.framework` into `Contents/Frameworks/`, and `executableTarget` adds `-rpath @executable_path/../Frameworks`. After inside-out ad-hoc signing, `codesign --verify --deep --strict` verifies the bundle.
- `Updater.swift` owns an `@MainActor UpdaterController` holding `SPUStandardUpdaterController`. It is constructed only by `LocalShareApp`; headless paths never touch it. Configuration lives in `Info.plist` (`SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`). When `SUPublicEDKey` is still the placeholder, the updater does not start.
- Trust is EdDSA: the private key signs update packages and the app embeds the public key. This is independent of code signing and notarization, so ad-hoc + unnotarized builds can still self-update safely. Updates installed by Sparkle are not quarantined, so the first manual approval does not repeat on later updates.
- CI `release.yml`: build -> dependency gate -> DMG -> GitHub Release -> `sign_update` EdDSA signature -> generate `appcast.xml` as a **Release asset**. It is not committed to git. Feed URL is `https://github.com/rrbe/LocalShare/releases/latest/download/appcast.xml`, which GitHub keeps pointing at the latest release asset.

### Text Transfer

Text Transfer expands "choose content -> scan on phone" from disk files to a text snippet. It has **two independent one-way channels**: `sharedText` for Mac -> phone and inbox for phone -> Mac.

- **v1 Mac -> phone**: `AppState.sharedText: String?` reuses almost all read-only serving. Text is another GET-served content type under reserved namespace `/ls/text`, matched before virtual-root keys. It can be shared alone or included in a multi-share virtual root. Browser navigation returns `TextViewer`; `?raw=1` and curl return `text/plain`. Phone page escapes text, has a large Copy button with `execCommand` fallback because plain HTTP LAN is not a secure context, and auto-links safe http(s) URLs.
- **v2 phone -> Mac**: independent inbox, no disk storage and no folder-share dependency. Gate is `textInboxEnabled`, opt-in and off by default. Enabling it starts the service if needed. `POST /ls/text` receives plain text; listing pages embed the send form. Limits: each message 64 KB, inbox 100 items with oldest eviction. `onReceiveText` hops from socket thread to `MainActor`; feedback stays in-app with no system notification.
- **Token is session-scoped**: `setSharedText` does **not** rotate the token, otherwise every text update would kick active viewers and break coexisting file-share links. Rotate only on session boundaries: `setShared`, `stop`, `clearShare`, and `stopTextTransfer`. Persistence toggles default off and are separate for shared text versus received text.

### Internationalization

- All user-visible copy is compiled into Swift string tables in `Lang.swift`. The app does not depend on resource bundles, so GUI, headless, and CLI paths do not need to locate localized files.
- **Two language domains are independent**: native app language comes from Settings (`AppState.langPref`: follow system / Chinese / English, persisted); web UI is decided **per request** from browser `Accept-Language` (`Lang.fromAcceptLanguage`, descending `q`, skip `q=0`). Web serving never reads the app setting.
- Copy has three categories: static strings use `L` with exhaustive enum cases returning `(zh, en)`; interpolation/plural/order-sensitive strings use `LStr`; JavaScript strings use `LStr.i18nJSON`, where `jsEscape` escapes `<` as `\u003c` to prevent premature `</script>`. Adding a language means adding branches to both `L` and `LStr`.

### Resilient UI

No Wi-Fi or private IP means no dead QR code; show guidance to connect to Wi-Fi. First server start may trigger the macOS firewall prompt; copy should tell users to click **Allow** because denying it is the most common reason scans fail. QR area keeps a concise troubleshooting line: same Wi-Fi and no guest/device isolation. Empty folders have a friendly state.

---

## 4. Build and Run

```bash
swift build -c release          # Build; first run fetches Swifter
swift test                      # XCTest pure-function tests
./build.sh                      # Assemble and ad-hoc sign -> dist/LocalShare.app
open dist/LocalShare.app        # Local GUI smoke test

# Headless end-to-end test for server logic
LS_HEADLESS=1 LS_FOLDER=/path/to/dir LS_TOKEN=testtoken LS_PORT=8099 .build/debug/LocalShare &
curl -s "http://127.0.0.1:8099/?t=testtoken"   # Should return a directory listing or index.html
```

Headless multi-share uses `LS_FOLDERS` separated by `:` or newlines. Enable upload with `LS_UPLOAD=1`, bind an interface with `LS_BIND=<ip>`, and test Text Transfer with `LS_TEXT` / `LS_RECV`. The two test layers (`swift test` and `tools/smoke-*.sh`) run in `.github/workflows/ci.yml` for every PR and `master` push.

**Sharing with a coworker**: copy `dist/*.app`; for the first launch, help them pass Gatekeeper once by opening the app, then System Settings -> Privacy & Security -> Open Anyway. macOS remembers this approval.

---

## 5. Non-Goals and Future Work

**Explicit non-goals:**

- Apple notarization, which requires a paid developer account.
- HTTPS with a self-signed certificate, which would replace scan-to-use with certificate warnings.
- Cross-network tunneling such as cloudflared, ngrok, or Tailscale.
- **Online edit/delete in the browser**. This is intentionally not supported: mobile browser editing is poor, overwrite/delete risks are high, and guest upload already covers the primary phone -> Mac need. `Permission.edit` and `Permission.del` remain `false`.

**Potential future work:**

- **Chunked upload**: bypass Swifter's whole-body-in-memory limitation by slicing on the frontend, appending chunks server-side, and atomically renaming on the final chunk. This would allow arbitrary size with constant memory and remove the 500 MB cap.
- **Better device-name lookup**: current lookup is best-effort `getnameinfo`; iPhones often do not resolve and fall back to IP. More accurate mDNS PTR lookup via `DNSServiceQueryRecord` is possible but more complex and still not guaranteed.
