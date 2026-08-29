# Rocket 🚀

A small, fast personal browser for macOS built on Safari's WebKit engine (WKWebView).
Pure Swift + AppKit, ~1,100 lines, no Xcode project, no dependencies — builds in a few
seconds with `swiftc`.

## Build & run

```bash
./build.sh
open build/Rocket.app
```

To install it into `/Applications`:

```bash
./build.sh --install
```

Use that rather than `cp -R build/Rocket.app /Applications/`. Copying over an existing
bundle merges into it in place, which leaves macOS holding a stale code signature for
that path — the app then dies on launch with "Code Signature Invalid" even though
`codesign --verify` reports it as valid. `--install` removes, re-copies and re-signs.
If you hit it anyway, `codesign --force --sign - /Applications/Rocket.app` recovers.

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

## Features

- **Tabs** — native macOS window tabs, exactly like Safari's: ⌘T new tab, ⌘W close,
  ⌃Tab / ⌃⇧Tab to cycle, **⌘1–⌘9 to jump to a tab** (⌘9 clamps to the last), ⇧⌘\
  tab overview, drag to reorder, merge/split windows.
- **New tab page** — local start page with a clock and a customizable wallpaper
  (Tools → Change New Tab Wallpaper…; Tools → Use Default New Tab Background reverts
  to the built-in gradient).
- **Learned suggestions** — a tiny neural net ((11+N)→16→N MLP, a couple of thousand
  parameters, pure Swift, zero dependencies) trains on your local visit history and shows a few suggestion chips on the new tab page for
  the sites you usually visit around now. Retrains automatically once a day and
  manually via Tools → New Tab Suggestions → Retrain Now; the same submenu can
  disable the feature (stops recording and suggesting), exclude the current
  website, re-include excluded sites, and wipe all suggestion data. History
  (capped at 3,000 visits), model, and training all stay in
  `~/Library/Application Support/Rocket/` — nothing leaves your Mac. Private
  windows are never recorded. Suggestions appear after ~25 recorded visits across
  3+ sites, and there's a **Retrain** button right under the chips when you want it
  refreshed immediately. Beyond day and time, the model learns from how long you
  actually spent on a site (counted only while that tab was front-most and Rocket was
  the active app, capped at 15 minutes per visit, so a tab left open overnight isn't
  mistaken for a favourite), which site you came from (so it learns that mail is
  usually followed by calendar), whether you're starting a fresh session or mid-flow,
  and how overdue a site is against its own visit rhythm — a daily read you haven't
  opened today outranks one you just closed, and the site you're coming from is never
  suggested back to you. Sign-in redirectors and link shorteners (`accounts.google.com`,
  `login.microsoftonline.com`, `t.co`…) are excluded **automatically**, worked out
  from how they behave — OAuth/SAML parameters, seconds-long dwell times, arriving
  by redirect — with no hardcoded domain list; Tools → New Tab Suggestions →
  Auto-Excluded Redirects shows what was caught and why. (Deliberately not ONNX: ONNX Runtime's on-device training build would
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
  recorders, and social pixels. Toggle in Tools → Block Ads and Trackers.
- **Fingerprinting protection** — on by default for all windows (Tools →
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
  Tools → Hide Cookie Banners.
- **Address bar** — shows the site, not the machinery: `google.com — hello` for a
  search, `example.com` for a page. Click in (or ⌘L) and the real URL returns for
  editing and copying. Subdomains stay visible on purpose — collapsing
  `accounts.google.com` to `google.com` is how phishing pages hide. Typing loads
  URLs directly, bare domains get `https://`, `localhost:…` gets `http://`, and
  anything else searches Google (Brave Search in incognito).
- **Search suggestions** — a dropdown of your bookmarks, your history and the search
  engine's own completions; ↑/↓ to pick, Return to go, Esc to dismiss. Private
  windows ask DuckDuckGo instead of Google. Toggle in Tools → Search Suggestions;
  turning it off keeps the local bookmark/history suggestions, which never leave
  the Mac.
- **Downloads viewer** — toolbar button (or ⌥⌘L) opens a Safari-style list with a
  live progress bar, transfer speed and time remaining, cancel, reveal in Finder,
  and double-click to open. Files land in `~/Downloads` with de-duplicated names,
  and downloads keep running after you close the tab that started them.
- **Malware scanning (VirusTotal)** — finished downloads are checked against
  VirusTotal, with the verdict shown inline in the downloads list. Tools → Download
  Scanning chooses between every download, only risky-or-large files (the browser
  classifies executables, installers, archives, macro documents, extensionless
  files, and anything ≥25 MB), or off. **Only the file's SHA-256 is sent by
  default** — the file itself is never uploaded unless you explicitly enable
  "Upload Unknown Files", since VirusTotal retains and shares uploads. The API key
  is kept in your login keychain, and can be supplied from a text file via
  "Use API Key File…".
- **Reopen closed tab** — ⇧⌘T walks back through the last 25 closed tabs. Incognito
  tabs are never recorded.
- **Back / Forward** — toolbar buttons, ⌘[ / ⌘], and two-finger swipe gestures.
- **Bookmarks** — ⌘D to add/remove, listed in the Bookmarks menu, persisted to
  `~/Library/Application Support/Rocket/bookmarks.json`.
- **Persistent logins** — cookies and site data use WebKit's persistent store, so you
  stay signed in between launches.
- **Private windows** — ⇧⌘N, ephemeral data store, tabs grouped separately.
- **Popup handling** — `target=_blank` / `window.open` open as new tabs; ⌘-click a
  link to open it in a background… well, a new tab.
- **Page zoom** (⌘+ / ⌘− / ⌘0), loading progress bar, stop/reload, HTTP basic auth
  prompts, file upload dialogs, JS alert/confirm/prompt, fullscreen video, camera/mic
  permission prompts, error pages.
- **Web Inspector** — right-click → Inspect Element (always enabled).
- **Default browser capable** — Rocket registers for `http`/`https`. Use **Rocket →
  Set Rocket as Default Browser** (it asks macOS directly and shows the system
  confirmation panel); the menu item disables itself and reads "Rocket Is Your
  Default Browser" once set. This also works when System Settings → Desktop & Dock
  omits Rocket from its dropdown, which happens when two copies of the app share one
  bundle id — keep a single copy (in `/Applications`) to avoid it. Links from other
  apps open as new tabs.
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
  AppDelegate.swift              menus, window registry, bookmarks menu, default browser
  BrowserWindowController.swift  one tab: toolbar, web view, navigation, downloads
  BookmarkStore.swift            JSON-backed bookmark persistence
  NewTabPage.swift               generated start page + wallpaper management
  ContentBlocker.swift           WebKit content rules: ad blocking + cookie banners
  HistoryStore.swift             local visit log for suggestions (capped, debounced)
  SuggestionEngine.swift         tiny MLP: trains on (day, time) → site, predicts chips
  WaypointDetector.swift         spots sign-in/redirect hosts from behaviour alone
  URLDisplay.swift               simplified address-bar text + search-query extraction
  SearchSuggestions.swift        address bar suggestions + the dropdown panel
  DownloadManager.swift          download progress, speed, and scan orchestration
  DownloadsPanel.swift           the downloads popover UI
  VirusTotal.swift               hash lookup / opt-in upload, keychain-stored key
  Views.swift                    address field, progress bar, bookmarks bar, URL resolver
Tools/
  AppIcon.swift                  the app icon, drawn in code at any size
  MakeIcon.swift                 renders the .iconset PNGs at build time
Info.plist                       bundle metadata, URL scheme registration, icon
build.sh                         swiftc build + icon generation + ad-hoc codesign
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
