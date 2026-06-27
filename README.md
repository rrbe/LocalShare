# LocalShare — share Mac files, scan a QR code to view or save them in your phone's browser

[简体中文](README_CN.md) | English

A small macOS app that moves files and text between your Mac and other devices (phone, tablet…) over WiFi — the other end just uses a browser, with no client to install.

- Pick a file or folder, scan the QR code that appears (or just open the link), and browse the files in your phone's browser (HTML, PDF, Markdown, images…)
- Two-way text transfer — type some text and share it via a QR code, or send text back from the phone to the Mac

<table>
  <tr>
    <td align="center"><img src="docs/images/screenshot-main-page.png" alt="Home" width="260"><br>Home</td>
    <td align="center"><img src="docs/images/screenshot-share-file.png" alt="Share Files" width="260"><br>Share Files</td>
    <td align="center"><img src="docs/images/screenshot-share-text.png" alt="Transfer Text" width="260"><br>Transfer Text</td>
  </tr>
</table>

## Features

- Share files and text by QR code, or just by opening the link
- Serves HTML / PDF / video / images; previews Markdown / JSON / CSV
- After you share, the other end can send files and text back
- Shows who's currently viewing
- `localshare` command line: bring up the window to share, or `--headless` to print the link and QR code in the terminal

## Why this app exists

- When AirDrop is flaky, or the other device isn't an Apple device
- iPhone Safari can't open local HTML files directly, so previewing the web pages you vibe-coded is awkward
- No need to spin up `python3 -m http.server`
- No need to install a client like LocalSend
- Preview only — no need to actually save files onto the phone
- Quickly pass text around, without relying on flaky Handoff

## GUI usage

Scan the QR code, or open the LAN address directly. If macOS shows a firewall prompt on first launch, click "Allow".

The QR code points to something like `http://192.168.x.x:8080/?t=<random-token>`: the link carries a one-time token, so whoever scans it gets in seamlessly, while anyone who only knows the IP:port cannot access it.

> ⚠️ Traffic is plain HTTP (unencrypted). Best avoided on public networks like airports and cafés.

## Terminal usage

In Settings → Command-Line Tool, click "Install". After that you can share from the terminal in one command:

```bash
localshare a.html b.pdf        # bring up the LocalShare window to share these files
localshare ~/Documents/report  # folders work the same; mix and match multiple items
localshare --headless ./dist   # no window — print the link and QR code in the terminal (Ctrl-C to stop)
```

## Download

https://github.com/rrbe/LocalShare/releases

## Notes

The app is ad-hoc signed, so **opening** it may be blocked by Gatekeeper (warning that it's "damaged" or "can't be opened").

- In System Settings → Privacy & Security → Security, find the prompt and click "Open Anyway"; or
- run the command below in the terminal to strip the quarantine attribute, then open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/LocalShare.app
```

## FAQ

**How do I open a local HTML file on my iPhone?**
iPhone Safari can't open `file://` HTML directly. Share the file (or its folder) with LocalShare and scan the QR code — Safari opens it from the local server, so links, CSS and images resolve normally.

**Does the other device need to install anything?**
No. Anything with a camera and a browser works — iPhone, iPad, Android, another Mac. Only the sharing Mac runs LocalShare.

**Does it need internet?**
No. Everything stays on your local network (the Mac and phone just need the same WiFi); nothing goes through the cloud.

**Is it secure?**
The link carries a one-time token, so knowing the IP:port isn't enough to get in. Traffic is plain HTTP, which is fine on a home/office network — avoid sharing sensitive files on public WiFi, and turn on "visible on current network only" to narrow exposure.

**Can the phone send files back to the Mac?**
Yes, if you turn on guest upload (off by default). Then the phone can upload photos and documents into the shared folder.

**Can I send a link or some text to my phone?**
Yes. Paste the text on the Mac and share it the same way — your phone opens it in the browser with a Copy button. You can also turn on the text inbox (off by default) so the phone can send text back to the Mac.

**Windows or Linux?**
LocalShare is macOS-only. On other platforms, dufs or LocalSend cover similar needs.

## License

MIT — see [LICENSE](LICENSE).

## Credits

This project was inspired by:

- [localsend](https://github.com/localsend/localsend)
- [dufs](https://github.com/sigoden/dufs)
