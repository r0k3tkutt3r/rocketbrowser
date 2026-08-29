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
- The app icon is generated at build time, not committed: `build.sh` compiles `Tools/*.swift` (`AppIcon.draw` + a `@main` CLI) into a throwaway binary, renders the 10 `.iconset` PNGs, and packs them with `iconutil` into `Contents/Resources/Rocket.icns`, which `CFBundleIconFile` points at. There are still no image assets in the repo. Finder, Launchpad and ⌘-Tab read only that `.icns` — `NSApp.applicationIconImage` would affect just the live Dock tile, which is why it is no longer set.
- `Tools/` is compiled separately from `Sources/` and must never be added to the app target: it has its own `@main`. Top-level statements still require `main.swift`, hence the `@main enum`.

## Architecture

**A tab IS a window.** Rocket uses native macOS window tabbing (Safari-style), not a custom tab bar. Every tab is an `NSWindow` owned by one `BrowserWindowController`, grouped by `window.tabbingIdentifier` (`rocket.browser`, or `rocket.private` for incognito windows so they never merge with normal ones). New tabs are created with `addTabbedWindow`. `AppDelegate` keeps every live controller in its `controllers` array (`register`/`unregister`, unregistered in `windowWillClose`) — that array is the only owner, so forgetting to register leaks nothing but makes the window vanish from app-level operations.

**Incognito is a session with a self-destructing store.** "New Incognito Window" (⇧⌘N) creates an `IncognitoSession`: a `WKWebsiteDataStore(forIdentifier: UUID)` on disk at `~/Library/WebKit/com.kushmodi.rocket/WebsiteDataStore/<uuid>` (lowercased), shared by every tab/popup spawned from that window (separate ⇧⌘N windows get separate sessions). Controllers `attach()`/`detach()`; when the last one detaches, the session wipes data via `removeData(allWebsiteDataTypes)` FIRST — `WKWebsiteDataStore.remove(forIdentifier:)` reports "in use (by network process)" for as long as the app runs, so it's only a retried best-effort — then force-deletes the store directory. `IncognitoSession.purgeLeftoverStores()` sweeps crash/quit orphans at launch (identifier stores are only ever incognito). `isPrivate` is computed from `incognitoSession != nil`. Incognito also forces both content-rule lists on (ignoring toggles), injects `PrivacyShield` anti-fingerprinting scripts (GPC, screen-size = window size, hardwareConcurrency 8, fixed storage quota — see the file for what's deliberately NOT spoofed and why), searches Brave Search instead of Google (`URLResolver.resolve(_:privateSearch:)`), and shows an in-memory start page (`NewTabPage.openIncognito`, loaded as a string so the URL stays `about:blank` — no file, no suggestion chips). External links from other apps route to `frontNormalBrowserController`, never into incognito. `ContentBlocker.apply(to:isIncognito:)` re-adds the PrivacyShield scripts because it wipes all user scripts — keep that invariant or settings toggles will strip incognito protections.

**Two menus, two jobs.** The View menu holds commands acting on the page in front of you (reload, zoom, bookmarks bar, full screen); the Tools menu holds everything that changes how Rocket itself behaves (ad/cookie/fingerprint toggles, search suggestions, downloads and their scanning policy, new-tab suggestions and wallpaper). Put a new feature toggle in Tools, not View.

**Menus work through the responder chain.** Almost all menu items have `target: nil`. The key window's `BrowserWindowController` handles them first; `AppDelegate` is the end of the chain and handles the no-window case (e.g. ⌘T with everything closed — both classes implement `newWindowForTab(_:)` on purpose). Enabled states, checkmarks, and dynamic titles ("Add Bookmark" ↔ "Remove Bookmark") live in `validateMenuItem` on both classes. Dynamic menus (Bookmarks, New Tab Suggestions) rebuild in `menuNeedsUpdate` via `NSMenuDelegate`.

**State flows through stores + one notification.** `BookmarkStore` and `HistoryStore` are singletons that persist JSON into `~/Library/Application Support/Rocket/`. Every `BookmarkStore` mutation posts `.bookmarksDidChange`; the bookmarks bar in every window and each window's star toolbar item observe it and rebuild. Don't mutate bookmark state any other way — save + notify happens inside the store.

**`Bookmark` is both bookmark and folder.** One struct: `children == nil` means bookmark, `children != nil` means folder (`isFolder`). `id: UUID` is generated in a custom `init(from:)` when missing, which is how pre-folder JSON files migrate silently. Store operations (`update`, `removeItem`, `moveBookmark`) recurse through `children`.

**Web view chrome is KVO.** `BrowserWindowController.startObservations()` observes `url`, `title`, `estimatedProgress`, `isLoading`, `canGoBack`, `canGoForward` on the web view and pushes into the URL field, window title, progress bar, and toolbar validation. The controller is also the `WKNavigationDelegate`, `WKUIDelegate`, and `WKDownloadDelegate`.

**Content blocking is native WebKit rules.** `ContentBlocker` compiles two curated `WKContentRuleList`s (ads/trackers, cookie-consent) from Swift arrays of domains via `WKContentRuleListStore`. The list identifier embeds a hash of the rules JSON — editing the domain arrays automatically recompiles on next launch and prunes stale compiled lists. `apply(to:)` is idempotent (remove-all then re-add) because popup web views share the opener's `WKUserContentController`. Toggles live in the Tools menu and reload every open tab through the `applyToAllWebViews` closure set by `AppDelegate`.

**Suggestions are a tiny local MLP, deliberately not ONNX/CoreML.** `SuggestionEngine` trains a softmax net (`TinyMLP`, plain Swift SGD) on `HistoryStore` visits. Inputs are `11 + vocab.count`: day-of-week one-hot (7), cyclical time of day (2), weekend flag (1), session-start flag (1), then a one-hot of the *previous* host — that block is what lets it learn transitions (mail → calendar). Training samples are weighted by recency × `engagementWeight` (attention, not visit count), and `predict` multiplies the net's output by a per-host "due-ness" factor from `context(from:at:)` — a site is lifted when it is overdue against its own median inter-visit gap and damped when you just left it; the host you came from is never suggested. Needs ≥25 visits across ≥3 hosts or `trainModel` returns nil. Retrains at most once per day, but keeps retrying until a first model exists — the "last trained" stamp is only written on success (this was a real bug; don't reintroduce it). Changing the feature layout makes older saved models stale: `modelMatchesCurrentFeatures` compares `mlp.inputSize` against `11 + vocab.count` and forces a retrain. A stale model still predicts rather than crashing (its narrower first layer just ignores the extra inputs), so widening the vector is safe; *narrowing* it would not be. The new tab page renders predictions as chips plus a retrain button.

**The address bar shows a simplified URL, never a lie.** `URLDisplay.displayString` renders `google.com — hello` for searches and the host (minus `www.`) otherwise; deeper subdomains are deliberately kept because collapsing `accounts.google.com` to `google.com` is the phishing trick. `URLField.onFocus` swaps the real URL back in the instant the field is focused, so editing, copying and ⌘L are unaffected, and `controlTextDidEndEditing` restores the short form.

**Waypoint hosts are detected, never listed.** `WaypointDetector` decides a host is a pass-through (sign-in redirector, SSO hop, shortener) from behaviour alone: OAuth/SAML query parameters on ≥50% of visits, or ≥80% of visits under `transientDwellLimit` (12s) *and* ≥50% arrived by redirect. A host with ≥3 visits past `destinationDwellFloor` (30s) is always a destination — that guard is what keeps `github.com` in the model despite its OAuth traffic. Feeding it requires `Visit.dwell` and `Visit.viaRedirect`: `BrowserWindowController` opens a visit in `didFinish`, closes it in `didStartProvisionalNavigation` and in `windowWillClose`. `SuggestionEngine` unions these hosts with the user's manual exclusions at both training and prediction time.

**Downloads outlive the tab that started them.** `DownloadsManager.shared` is the `WKDownloadDelegate`, not the window controller, so closing a tab never kills its download. Speed comes from sampling `WKDownload.progress` on a 0.5s timer with exponential smoothing; the timer stops itself when nothing is running. Every mutation posts `.downloadsDidChange`.

**VirusTotal sends a hash, not your file.** `VirusTotal.scan` hashes locally (streaming SHA-256) and looks the hash up; a file is only ever uploaded when `uploadsUnknownFiles` is explicitly enabled, which is off by default and gated behind a confirmation because VirusTotal retains and shares uploads. The key lives in the login keychain; `importKeyFromFileIfAvailable()` re-reads a plain-text key file at every launch (path in `VTKeyFilePath`, or `virustotalkey.txt` in Application Support) and overwrites the keychain copy, which also re-establishes the app's own ownership of the item. What counts as worth scanning is `DownloadRiskAssessor` — file *types* (executables, archives, macro documents, extensionless files) plus a 25 MB size floor.

**Attention is measured, not assumed.** `Visit.activeTime` counts only seconds where the tab was front-most *and* Rocket was the active app, capped at `Visit.activeTimeCap` (15 min) so one long session cannot dominate. `BrowserWindowController` accumulates it via `resumeActiveTiming`/`pauseActiveTiming`, driven by `windowDidBecomeKey`/`windowDidResignKey` and the `NSApplication` active notifications, and hands it to `closeVisit(id:at:activeTime:)`. `Visit.engagementSeconds` falls back to wall-clock `dwell` for history recorded before this existed.

**The new tab page talks back over one message handler.** `BrowserWindowController` registers a `WKScriptMessageHandler` named `rocket` (removing any existing one first — popups share the opener's `userContentController`, and a duplicate name throws) and drops it in `windowWillClose`, since the content controller retains its handlers. The retrain button posts `{action:"retrain"}`; Swift retrains and regenerates the page, which is what renders the new chips.

**Popup contract.** In `createWebViewWith`, the new `WKWebView` MUST be built with the exact configuration WebKit passes in — never a copy. Everywhere else (⌘T, ⌘-click), new tabs copy the current web view's configuration so private tabs stay private.

## Gotchas

- `WKWebsiteDataStore.fetchAllDataStoreIdentifiers` SEGFAULTS if it is the process's first WebKit call (its completion dispatches to a WebKit RunLoop that only other WebKit entry points initialize). `IncognitoSession.purgeLeftoverStores` touches `WKWebsiteDataStore.default()` first for exactly this reason — keep that line, and warm WebKit the same way before any early data-store API call.
- `PrivacyShield` scripts are injected into ALL windows while `FingerprintProtection` is on (incognito: always, regardless of the toggle) — the injection decision lives in `ContentBlocker.apply`. Canvas/audio farbling noise is seeded per app launch (`sessionSeed`) XOR per site origin: deterministic within a session so repeated reads agree, different across launches so the hash can't track. Keep that determinism — pure random noise per read is detectable and can break sites.
- Never install by `cp -R build/Rocket.app /Applications/` over an existing copy. cp merges the new files into the old bundle in place, and macOS keeps that path's previous code signature cached — the result passes `codesign --verify` on disk but the kernel SIGKILLs it at launch with "Code Signature Invalid" (termination namespace CODESIGNING, "Taskgated Invalid Signature"). `./build.sh --install` does it correctly: `rm -rf` the destination, `ditto`, then re-sign. Re-signing an already-broken copy in place (`codesign --force --sign - /Applications/Rocket.app`) is the recovery.
- Two copies of Rocket with the same bundle id (`/Applications/Rocket.app` plus `build/Rocket.app`) confuse Launch Services enough that System Settings drops Rocket from its "Default web browser" list. `AppDelegate.setAsDefaultBrowser` bypasses that by calling `NSWorkspace.setDefaultApplication(at:toOpenURLsWithScheme:)` for https then http; `isDefaultBrowser` compares bundle ids (not paths) because Launch Services stores the handler by id. Setting a `build/` copy as default is a trap — `build.sh` `rm -rf`s that bundle every build — hence the warning alert for non-`/Applications` copies.
- `nextNavigationIsUserInitiated` exists so a typed URL or a bookmark is not misfiled as a redirect: `load(_:)` sets it, and `decidePolicyFor` consumes it when classifying a `.other` navigation. Break this and the waypoint detector starts excluding sites you actually visit.
- The downloads toolbar item MUST keep its custom `NSButton` view. A plain image `NSToolbarItem` has a nil `view`, and the popover then has nothing to anchor to (this was a real bug — the panel silently never opened).
- The Delete key maps to "go back" in stock WKWebView. It's disabled via the private `backspaceKeyNavigationEnabled` WebKit preference (set through KVC, guarded by `responds(to:)` in `BrowserWindowController.init`). Keep the guard.
- The user agent is set to exactly match Safari (`applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"`); some sites (Google sign-in) break on the default WKWebView agent.
- macOS gives no public API for Apple Passwords / iCloud Keychain autofill in WKWebView — it's Safari-only. Don't chase it; logins persist via the default `WKWebsiteDataStore` instead.
- `NewTabPage.isNewTabURL` distinguishes the internal start page (a `file://` URL) from real pages — it gates history recording, bookmarking, and the URL field showing empty. Check it when adding anything that reacts to the current URL.
- History recording is skipped for incognito windows, non-http(s) schemes, and the navigation right after an error page (`suppressHistoryOnce`).
- Settings are plain `UserDefaults` keys read with `object(forKey:) as? Bool ?? true` so the default is "on": `ShowBookmarksBar`, `BlockAds`, `HideCookieBanners`, `FingerprintProtection`, `SuggestionsEnabled`, `SearchSuggestions`, plus `VTScanPolicy`, `VTUploadUnknownFiles`, `VTKeyFilePath`, plus `SuggestionsExcludedHosts`, `SuggestionsLastTrained`, `Homepage`.
- All user data lives in `~/Library/Application Support/Rocket/` (`bookmarks.json`, `history.json`, `suggestions.json`, `newtab.html`, `wallpaper-*`). Wallpaper files get a timestamped name on every change for cache busting.
