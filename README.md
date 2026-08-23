# Rocket 🚀

A small, fast personal browser for macOS built on Safari's WebKit engine (WKWebView).
Pure Swift + AppKit, ~1,100 lines, no Xcode project, no dependencies — builds in a few
seconds with `swiftc`.

## Build & run

```bash
./build.sh
open build/Rocket.app
```

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

## Features

- **Tabs** — native macOS window tabs, exactly like Safari's: ⌘T new tab, ⌘W close,
  ⌃Tab / ⌃⇧Tab to cycle, **⌘1–⌘9 to jump to a tab** (⌘9 clamps to the last), ⇧⌘\
  tab overview, drag to reorder, merge/split windows.
- **New tab page** — local start page with a clock and a customizable wallpaper
  (View → Change New Tab Wallpaper…; View → Use Default New Tab Background reverts
  to the built-in gradient).
- **Learned suggestions** — a tiny neural net (10→16→N MLP, ~1,300 parameters,
  pure Swift, zero dependencies) trains on your local visit history — day of week
  and time of day → site — and shows a few suggestion chips on the new tab page for
  the sites you usually visit around now. Retrains automatically once a day and
  manually via View → New Tab Suggestions → Retrain Now; the same submenu can
  disable the feature (stops recording and suggesting), exclude the current
  website, re-include excluded sites, and wipe all suggestion data. History
  (capped at 3,000 visits), model, and training all stay in
  `~/Library/Application Support/Rocket/` — nothing leaves your Mac. Private
  windows are never recorded. Suggestions appear after ~25 recorded visits across
  3+ sites. (Deliberately not ONNX: ONNX Runtime's on-device training build would
  add a 50 MB+ dylib and an offline Python toolchain for a 10 KB model — a plain
  Swift MLP does the same job with zero overhead.)
- **Bookmarks bar** — under the toolbar, scrolls horizontally when full, ⌘-click a
  bookmark to open it in a new tab. Toggle with ⇧⌘B. Right-click the bar or any
  button to add the current page, add a page by URL, edit titles/URLs, delete, and
  create **folders**; clicking a folder drops down its bookmarks (with add/edit/
  delete entries for that folder). **Drag** a bookmark button onto a folder to move
  it inside; drop it on empty bar space to move it back to the top level. Old flat
  `bookmarks.json` files migrate automatically.
- **Ad & tracker blocking** — native WebKit content rules (the same engine as Safari
  content blockers) with a curated blocklist of ~65 ad networks, trackers, session
  recorders, and social pixels. Toggle in View → Block Ads and Trackers.
- **Fingerprinting protection** — on by default for all windows (View →
  Fingerprinting Protection to toggle; incognito windows are always protected).
  Static overrides blend Rocket into the Safari crowd (GPC signal, CPU cores,
  screen geometry, color depth, WebGL renderer, storage quota); canvas and audio
  readouts get imperceptible Brave-style noise seeded per launch and per site, so
  those hashes change every launch and can't identify or track you. Note: EFF's
  coveryourtracks.eff.org may still label the fingerprint "unique" — with a
  randomized fingerprint that uniqueness is worthless to trackers because it never
  repeats; run the test twice across app restarts to see the hashes change.
- **Cookie popup removal** — blocks the major consent-platform CDNs (OneTrust,
  Cookiebot, Sourcepoint, Didomi, Usercentrics, Quantcast, TrustArc, …), hides known
  banner elements, and unlocks page scrolling the banners leave behind. Toggle in
  View → Hide Cookie Banners.
- **Address bar** — ⌘L to focus; loads URLs directly, bare domains get `https://`,
  `localhost:…` gets `http://`, anything else searches Google.
- **Back / Forward** — toolbar buttons, ⌘[ / ⌘], and two-finger swipe gestures.
- **Bookmarks** — ⌘D to add/remove, listed in the Bookmarks menu, persisted to
  `~/Library/Application Support/Rocket/bookmarks.json`.
- **Persistent logins** — cookies and site data use WebKit's persistent store, so you
  stay signed in between launches.
- **Private windows** — ⇧⌘N, ephemeral data store, tabs grouped separately.
- **Downloads** — saved to `~/Downloads` with automatic de-duplicated names.
- **Popup handling** — `target=_blank` / `window.open` open as new tabs; ⌘-click a
  link to open it in a background… well, a new tab.
- **Page zoom** (⌘+ / ⌘− / ⌘0), loading progress bar, stop/reload, HTTP basic auth
  prompts, file upload dialogs, JS alert/confirm/prompt, fullscreen video, camera/mic
  permission prompts, error pages.
- **Web Inspector** — right-click → Inspect Element (always enabled).
- **Default browser capable** — Rocket registers for `http`/`https`, so you can pick
  it in System Settings → Desktop & Dock → Default web browser. Links from other apps
  open as new tabs.
- **Safari user agent** — sites (including Google sign-in) treat it as Safari.
- **No backspace navigation** — the Delete key never triggers "go back" (WebKit's
  default in WKWebView); it still deletes text in forms. Use ⌘[ or swipe instead.

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

## Headless / background testing

```bash
open -ngj build/Rocket.app   # new instance, hidden, no focus steal
pkill -x Rocket              # quit all instances
```

## Layout

```
Sources/
  main.swift                     entry point
  AppDelegate.swift              menus, window registry, bookmarks menu, app icon
  BrowserWindowController.swift  one tab: toolbar, web view, navigation, downloads
  BookmarkStore.swift            JSON-backed bookmark persistence
  NewTabPage.swift               generated start page + wallpaper management
  ContentBlocker.swift           WebKit content rules: ad blocking + cookie banners
  HistoryStore.swift             local visit log for suggestions (capped, debounced)
  SuggestionEngine.swift         tiny MLP: trains on (day, time) → site, predicts chips
  Views.swift                    address field, progress bar, bookmarks bar, URL resolver
Info.plist                       bundle metadata, URL scheme registration
build.sh                         swiftc build + ad-hoc codesign
```

## Known limitations

- No history UI, no find-in-page, no favicons in tabs (kept intentionally small).
- The blocklist is curated and compact, not a full EasyList — it catches the big ad
  networks and consent platforms, not every regional list entry. Add domains in
  `Sources/ContentBlocker.swift`; the rules recompile automatically on next launch.
- Blocking `googletagmanager.com` / `connect.facebook.net` can break the rare site
  that gates functionality on them — flip off "Block Ads and Trackers" for a moment
  if a page misbehaves.
- Passkeys/WebAuthn for arbitrary sites needs Apple's web-browser entitlement and a
  signed provisioning profile, so it's not wired up.
- The dock icon is drawn at runtime; the Finder shows a generic icon.
