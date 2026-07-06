# Changelog

## [0.10.0] - 2026-07-06

- Added the macOS Share Extension, so files and folders can be sent to LocalShare directly from the system Share menu
- Internationalized the project documentation so setup, architecture, design, and contributor guidance are available in English

## [0.9.1] - 2026-06-28

- Reworked Settings into grouped cards so sections are clearer and easier to scan
- Added explanatory copy for restoring the default window size

## [0.9.0] - 2026-06-27

- Added Text Transfer for sending text both ways between Mac and phone; scan once to send or receive long text and links without using a chat app as a relay
- Added Chinese and English UI support: the native app can follow the system language or be switched manually, while the browser UI follows the visitor's browser language
- Moved shared files to a secondary page with back navigation, so the home screen can return to the QR code while transfers continue in the background
- Stopped replaying the last share on cold launch; recent shares can now be restarted manually for a safer default

## [0.8.2] - 2026-06-18

- Added an automatic update setting: background checks can be disabled while the Check for Updates menu item remains available
- Added a Settings entry point to each main title bar, so Settings can be opened without first sharing a folder
- Regrouped Settings into Network, Access, Appearance, Home, and Command Line sections
- Increased the default window width to avoid truncating port numbers in the address field
- Fixed several visual flickers when entering Settings

## [0.8.1] - 2026-06-17

- Fixed a bright artifact that appeared around the notched card edge under shadow
- Unified border weights across cards, outline buttons, and Settings segmented controls for a calmer resting state

## [0.8.0] - 2026-06-17

- Share links are now visible only on the current Wi-Fi by default; they expire automatically after switching networks or disconnecting
- Added live visitor visibility with online counts and device names; details show each visitor's address and session duration
- Added a browser notice that LAN transfers are sent over plain HTTP
- Hardened browser security: blocked XSS vectors in Markdown preview, cleaned access tokens from browser history, defanged executable uploaded documents and images, and added quarantine metadata

## [0.7.0] - 2026-06-12

- Moved automatic update feeds to GitHub Releases; appcast files are now published with each release and fetched from a stable latest-release URL
- Release notes are now maintained through version tag annotations and displayed automatically on the Release page

## [0.6.0] - 2026-06-12

- Added guest uploads for single-folder shares: visitors can upload files into the current folder from the browser; shares remain read-only by default, switch back to read-only after changing shares, and enforce a 500 MB per-file limit
- Added browser previews for Markdown, JSON, and CSV: files render in place, relative references keep working, and `?raw=1` or curl still returns the original text
- Generated a fresh link for every share: old links stop working immediately after stopping or changing a share, and the window URL matches copied links
- Added the "N people browsing" indicator to the share window
- Added parent-directory navigation to listing pages and opened files in new tabs
- Made every selected item in a multi-share card revealable in Finder

## [0.5.0] - 2026-06-10

- Added the `localshare` command: share paths from Terminal, forward to the GUI by default, or run a foreground server with `--headless`
- Added one-click install and uninstall controls for the command-line tool in Settings
- Added a persistent menu bar icon with LocalShare and Quit actions
- Added a setting to hide the Recent Shares section

## [0.4.0] - 2026-06-10

- Added support for sharing multiple files and folders at once

## [0.3.0] - 2026-06-09

- Added Sparkle automatic updates; this is the first version that can update itself

## [0.2.0] - 2026-06-08

- Added drag-and-drop sharing for files and folders
- Split share cards by file type and added format labels, Finder reveal, and path copy actions

## [0.1.2] - 2026-06-05

- Added LAN file sharing: choose a folder, get a QR code, and let phones on the same Wi-Fi browse it in a browser
- Added single-file sharing with browser-side type filtering
- Added the warm-paper broadcast-style interface, matching browser listing pages, and dark mode
- Fixed the window not appearing after a clean launch
