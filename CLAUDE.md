# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Rocket is a personal macOS web browser built on WKWebView. Pure AppKit, programmatic UI (no storyboards, no SwiftUI), no third-party dependencies, no Xcode project. One Swift module in `Sources/`, compiled directly with `swiftc`.

## Commands

Build the app bundle (output: `build/Rocket.app`):

```bash
./build.sh
```

Run it:

```bash
open build/Rocket.app
```

There is no test target. Logic is verified with small throwaway harnesses: compile the file under test together with a `main.swift` full of asserts, then run it. Example:

```bash
swiftc -swift-version 5 Sources/BookmarkStore.swift /path/to/test/main.swift -o /tmp/t && /tmp/t
```

`BookmarkStore`, `HistoryStore`, and `SuggestionEngine` are written to support this: stores take an injectable `fileURL` in `init`, and the ML functions (`SuggestionEngine.trainModel` / `.predict` / `.features`) are pure static functions with no UI or singleton dependencies. Keep new logic testable the same way.

To verify the app launches without stealing the user's screen, use `open -ngj build/Rocket.app` (new instance, hidden, no focus), then check `pgrep -x Rocket` and `ls ~/Library/DiagnosticReports | grep -i rocket`. The sandbox blocks `kill`; ask the user to run `pkill -x Rocket`. If Rocket is already running, plain `open` will focus the old instance instead of launching the new build — the user must quit first.

## Build system facts

- `build.sh` compiles `Sources/*.swift` with `-O -swift-version 5`, copies `Info.plist` into the bundle, and ad-hoc codesigns. Stay in Swift 5 language mode; the code is not strict-concurrency clean.
- `main.swift` is the only file allowed top-level statements.
- Minimum macOS is 14 (`-target arm64-apple-macos14.0` and `LSMinimumSystemVersion`). APIs newer than macOS 14 need an `#available` guard.
- The app icon is drawn at runtime (`AppDelegate.makeAppIcon`) — there are no image assets anywhere.

## Architecture

**A tab IS a window.** Rocket uses native macOS window tabbing (Safari-style), not a custom tab bar. Every tab is an `NSWindow` owned by one `BrowserWindowController`, grouped by `window.tabbingIdentifier` (`rocket.browser`, or `rocket.private` for incognito windows so they never merge with normal ones). New tabs are created with `addTabbedWindow`. `AppDelegate` keeps every live controller in its `controllers` array (`register`/`unregister`, unregistered in `windowWillClose`) — that array is the only owner, so forgetting to register leaks nothing but makes the window vanish from app-level operations.

**Incognito is a session with a self-destructing store.** "New Incognito Window" (⇧⌘N) creates an `IncognitoSession`: a `WKWebsiteDataStore(forIdentifier: UUID)` on disk at `~/Library/WebKit/com.kushmodi.rocket/WebsiteDataStore/<uuid>` (lowercased), shared by every tab/popup spawned from that window (separate ⇧⌘N windows get separate sessions). Controllers `attach()`/`detach()`; when the last one detaches, the session wipes data via `removeData(allWebsiteDataTypes)` FIRST — `WKWebsiteDataStore.remove(forIdentifier:)` reports "in use (by network process)" for as long as the app runs, so it's only a retried best-effort — then force-deletes the store directory. `IncognitoSession.purgeLeftoverStores()` sweeps crash/quit orphans at launch (identifier stores are only ever incognito). `isPrivate` is computed from `incognitoSession != nil`. Incognito also forces both content-rule lists on (ignoring toggles), injects `PrivacyShield` anti-fingerprinting scripts (GPC, screen-size = window size, hardwareConcurrency 8, fixed storage quota — see the file for what's deliberately NOT spoofed and why), searches DuckDuckGo instead of Google (`URLResolver.resolve(_:privateSearch:)`), and shows an in-memory start page (`NewTabPage.openIncognito`, loaded as a string so the URL stays `about:blank` — no file, no suggestion chips). External links from other apps route to `frontNormalBrowserController`, never into incognito. `ContentBlocker.apply(to:isIncognito:)` re-adds the PrivacyShield scripts because it wipes all user scripts — keep that invariant or settings toggles will strip incognito protections.

**Menus work through the responder chain.** Almost all menu items have `target: nil`. The key window's `BrowserWindowController` handles them first; `AppDelegate` is the end of the chain and handles the no-window case (e.g. ⌘T with everything closed — both classes implement `newWindowForTab(_:)` on purpose). Enabled states, checkmarks, and dynamic titles ("Add Bookmark" ↔ "Remove Bookmark") live in `validateMenuItem` on both classes. Dynamic menus (Bookmarks, New Tab Suggestions) rebuild in `menuNeedsUpdate` via `NSMenuDelegate`.

**State flows through stores + one notification.** `BookmarkStore` and `HistoryStore` are singletons that persist JSON into `~/Library/Application Support/Rocket/`. Every `BookmarkStore` mutation posts `.bookmarksDidChange`; the bookmarks bar in every window and each window's star toolbar item observe it and rebuild. Don't mutate bookmark state any other way — save + notify happens inside the store.

**`Bookmark` is both bookmark and folder.** One struct: `children == nil` means bookmark, `children != nil` means folder (`isFolder`). `id: UUID` is generated in a custom `init(from:)` when missing, which is how pre-folder JSON files migrate silently. Store operations (`update`, `removeItem`, `moveBookmark`) recurse through `children`.

**Web view chrome is KVO.** `BrowserWindowController.startObservations()` observes `url`, `title`, `estimatedProgress`, `isLoading`, `canGoBack`, `canGoForward` on the web view and pushes into the URL field, window title, progress bar, and toolbar validation. The controller is also the `WKNavigationDelegate`, `WKUIDelegate`, and `WKDownloadDelegate`.

**Content blocking is native WebKit rules.** `ContentBlocker` compiles two curated `WKContentRuleList`s (ads/trackers, cookie-consent) from Swift arrays of domains via `WKContentRuleListStore`. The list identifier embeds a hash of the rules JSON — editing the domain arrays automatically recompiles on next launch and prunes stale compiled lists. `apply(to:)` is idempotent (remove-all then re-add) because popup web views share the opener's `WKUserContentController`. Toggles live in the View menu and reload every open tab through the `applyToAllWebViews` closure set by `AppDelegate`.

**Suggestions are a tiny local MLP, deliberately not ONNX/CoreML.** `SuggestionEngine` trains a 10→16→N softmax net (`TinyMLP`, plain Swift SGD) on `HistoryStore` visits: day-of-week one-hot + cyclical time-of-day → host. Needs ≥25 visits across ≥3 hosts or `trainModel` returns nil. Retrains at most once per day, but keeps retrying until a first model exists — the "last trained" stamp is only written on success (this was a real bug; don't reintroduce it). Excluded hosts are filtered at both training (vocab) and prediction. The new tab page (`NewTabPage`, a generated local HTML file in Application Support) renders the predictions as chips each time it's opened.

**Popup contract.** In `createWebViewWith`, the new `WKWebView` MUST be built with the exact configuration WebKit passes in — never a copy. Everywhere else (⌘T, ⌘-click), new tabs copy the current web view's configuration so private tabs stay private.

## Gotchas

- The Delete key maps to "go back" in stock WKWebView. It's disabled via the private `backspaceKeyNavigationEnabled` WebKit preference (set through KVC, guarded by `responds(to:)` in `BrowserWindowController.init`). Keep the guard.
- The user agent is set to exactly match Safari (`applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"`); some sites (Google sign-in) break on the default WKWebView agent.
- macOS gives no public API for Apple Passwords / iCloud Keychain autofill in WKWebView — it's Safari-only. Don't chase it; logins persist via the default `WKWebsiteDataStore` instead.
- `NewTabPage.isNewTabURL` distinguishes the internal start page (a `file://` URL) from real pages — it gates history recording, bookmarking, and the URL field showing empty. Check it when adding anything that reacts to the current URL.
- History recording is skipped for incognito windows, non-http(s) schemes, and the navigation right after an error page (`suppressHistoryOnce`).
- Settings are plain `UserDefaults` keys read with `object(forKey:) as? Bool ?? true` so the default is "on": `ShowBookmarksBar`, `BlockAds`, `HideCookieBanners`, `SuggestionsEnabled`, plus `SuggestionsExcludedHosts`, `SuggestionsLastTrained`, `Homepage`.
- All user data lives in `~/Library/Application Support/Rocket/` (`bookmarks.json`, `history.json`, `suggestions.json`, `newtab.html`, `wallpaper-*`). Wallpaper files get a timestamped name on every change for cache busting.
