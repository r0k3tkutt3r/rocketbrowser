# Rocket 🚀

A small, fast personal browser for macOS built on Safari's WebKit engine (WKWebView).
Pure Swift + AppKit, ~1,100 lines, no Xcode project, no dependencies — builds in a few
seconds with `swiftc`.

## Features

- Tabs — native macOS window tabs (⌘T / ⌘W, ⌘1–⌘9 to jump, drag to reorder)
- New tab page — local start page with customizable wallpaper
- Learned suggestions — tiny local neural net that suggests sites you usually visit at this time
- Bookmarks bar — folders, drag to move, ⇧⌘B to toggle
- Ad & tracker blocking — native WebKit rules with curated ~65-domain blocklist
- Fingerprinting protection — static overrides + canvas/audio noise seeded per launch and site
- Browser promo removal — automatic "install Chrome" removal matched by shape
- Cookie banner removal — blocks major consent-platform CDNs
- Address bar — simplified display (⌘L to edit, ⌘D to bookmark)
- Search suggestions — bookmarks/history/search engine with usage-based ranking
- History window — searchable, grouped by date (⌘Y)
- Session restore — optional, with ⇧⌘T surviving restart
- Downloads viewer — progress bar, speed, VirusTotal scanning (hash-only by default)
- Private windows — ⇧⌘N with ephemeral data store
- Persistent logins — via WebKit's persistent cookie store
- Back/forward — toolbar buttons, ⌘[ / ⌘], and two-finger swipe
- Popup handling — `target=_blank` and `window.open` open as tabs
- Page zoom — ⌘+ / ⌘− / ⌘0
- Web Inspector — right-click → Inspect Element
- Default browser capable — register as http/https handler
- No backspace navigation — Delete key doesn't trigger "go back"

## Apple Passwords autofill — the honest status

Apple does **not** expose Passwords/iCloud Keychain autofill to third-party browsers'
web views on macOS: it's wired into Safari itself, not into WKWebView. The official
iCloud Passwords extension exists only for Chromium/Firefox and can't be loaded into a
WKWebView app, and there is no public API for it through macOS 26/27.

What you can do instead:

- Use the **Passwords menu bar item** (System Settings → enable in the Passwords app):
  it detects the frontmost site and lets you copy/fill credentials into Rocket.
- Rocket's persistent sessions mean you rarely re-enter passwords — sites keep you
  signed in like Safari does.

If Apple ever ships a credential API for embedders, it belongs in
`BrowserWindowController.makeConfiguration()`.

## Customizing

```bash
# Change the homepage / new-tab page (default: google.com)
defaults write com.kushmodi.rocket Homepage "https://duckduckgo.com"
```

Search engine: edit `URLResolver` in `Sources/Views.swift`.

