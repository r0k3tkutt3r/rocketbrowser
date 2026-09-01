# Session restore + history screen

Two features for Rocket, designed together because both read the same question:
"what was I doing before?"

- **Session restore** — reopen the tabs you had when you quit. Optional.
- **History screen** — find a page you read once, which the address bar deliberately
  will not offer you.

Read `CLAUDE.md` first. Everything below assumes its architecture section.

---

## 1. Session restore

### Why

`AppDelegate.applicationDidFinishLaunching` ends with an unconditional
`openNewWindow(url: nil)`. Every launch is one empty tab; quitting with N tabs loses
all of them. Nothing implements NSWindow restoration. The ⇧⌘T stack
(`AppDelegate.closedTabs`, capped at 25) is in-memory only, so it dies on quit too.

### Shape

Session data is **always saved**. The preference controls only whether launch
*consumes* it automatically.

- `Tools → Restore Tabs on Launch` — key `RestoreSession`, **default off**.
- `History → Reopen Last Session` — works regardless of the toggle.

This makes "optional" mean both things at once: no change to launch behaviour unless
you ask for it, but a one-off recovery is always one menu item away.

### `Sources/SessionStore.swift` (new)

```swift
struct SessionTab: Codable    { let url: String; let title: String? }
struct SessionWindow: Codable { let tabs: [SessionTab] }
struct SavedSession: Codable  { let windows: [SessionWindow]
                                let closedTabs: [SessionTab]
                                let savedAt: Date }
```

`SessionStore` persists `session.json` into `~/Library/Application Support/Rocket/`,
alongside the other stores, and takes an injectable `fileURL` in `init` so it is
testable the way `BookmarkStore` and `HistoryStore` are.

Interface: `load() -> SavedSession?`, `save(_:)`, `scheduleSave(_:)` (2s debounce,
same idiom as `HistoryStore.scheduleSave`), `flush()`.

Snapshotting is **not** in the store — it needs live `NSWindow`s, which are not
testable. `AppDelegate` builds the snapshot and hands it over. The pure part of that
work is factored out so it can be tested:

```swift
enum SessionSnapshot {
    struct Entry { let url: String; let title: String?
                   let groupKey: Int; let isPrivate: Bool }
    static func build(from entries: [Entry], closedTabs: [SessionTab]) -> SavedSession
}
```

`build` drops private entries, drops new-tab-page entries, drops windows left with no
tabs, and preserves both group order and within-group tab order.

### Grouping

A tab **is** a window (see CLAUDE.md). Windows are grouped by `window.tabGroup`, and
tab order within a group comes from walking `group.windows` in order and mapping each
back to its controller. A controller with no `tabGroup` is its own group. This is what
makes window/tab structure survive rather than flattening into a URL list.

### Save triggers

- `applicationWillTerminate` — `flush()`, next to the existing `HistoryStore.shared.flush()`.
- A 2s debounced save on navigation finish, so a crash or force-quit still leaves a
  recent session.

Incognito controllers are never snapshotted, mirroring the rule `recordClosedTab`
already follows (`!isPrivate`).

### The overwrite trap

With the toggle off, launch opens one empty tab, the debounced save fires, and the
previous session is overwritten *before the user can reach the menu item*. The feature
would appear to work and then silently do nothing.

Fix: `AppDelegate` reads the saved session into memory once at launch and keeps it.
`Reopen Last Session` always replays that **in-memory** copy and never re-reads disk,
so it stays valid for the whole app run no matter what the live session writes.

Accepted loss: relaunch twice without browsing, toggle off, and the old session is
gone. The alternative — refusing to overwrite with an empty session — was rejected
because it makes restore-on-launch resurrect tabs you deliberately closed, which is
worse and harder to reason about.

### Closed-tab stack

`closedTabs` rides in the same file and is loaded back into `AppDelegate` at launch, so
⇧⌘T survives a restart. Existing cap of 25 is unchanged.

### Settings convention deviation

Every other setting in this codebase reads `object(forKey:) as? Bool ?? true` so the
default is "on". `RestoreSession` reads `?? false` on purpose — restoring tabs changes
launch behaviour and must be opted into. Recorded in CLAUDE.md so it does not read as
a typo.

---

## 2. History screen

### Why

There is no history UI at all. `HistoryRanker` deliberately suppresses one-off deep
URLs from the address bar (`minimumVisitsForDeepURL`, `minimumEngagementForDeepURL`),
so a page read once last week is currently unreachable by any means. Closing that gap
is the whole point of this screen.

### `Sources/HistoryWindow.swift` (new)

An `NSWindowController` owning one shared window, shown with `⌘Y`. Handled by
`AppDelegate`, not `BrowserWindowController`, so it works with no browser window open.

Layout: `NSSearchField` at the top, view-based `NSTableView` in a scroll view,
"Clear History…" at the bottom.

Rows are a flattened list so one table renders both headers and visits:

```swift
enum Row { case header(String), visit(Visit) }
```

### Grouping

```swift
enum HistoryGrouping {
    static func sections(for visits: [Visit], now: Date) -> [Row]
}
```

Pure, therefore testable. Today / Yesterday / weekday name within the last 7 days /
medium date beyond that. Newest first.

### Titles

`Visit` records url/host/ts only, so rows could otherwise show nothing but hostnames.
Add an optional `title` to `Visit`, written from the `\.title` KVO observation
`BrowserWindowController.startObservations` already runs, via a new
`HistoryStore.setTitle(id:_:)`.

Old entries decode with `title == nil` through the existing `decodeIfPresent`
migration idiom in `Visit.init(from:)` — no file migration, no version field. Rows
without a title fall back to host + path.

### Search

Plain case-insensitive substring match over title, url and host, in reverse
chronological order.

**Deliberately not `HistoryRanker`.** The ranker exists to suppress one-off deep URLs;
this screen exists to surface them. Reusing it here would hide exactly the pages the
feature was built to find. This belongs in CLAUDE.md next to the existing
"do NOT reuse `WaypointDetector` for address-bar suggestions" warning — same class of
mistake, opposite component.

### Deletion

- ⌫ on the selection, plus a context menu item → new `HistoryStore.remove(ids:)`.
- "Clear History…" → confirmation alert → existing `HistoryStore.clear()`.

Both mutate **and** save **and** notify inside the store, mirroring the
`BookmarkStore` rule. New `Notification.Name.historyDidChange`, observed by the
history window, mirroring `.bookmarksDidChange`.

### Retrain on delete

Deleting history removes those visits from what `SuggestionEngine` trains on, so a
delete schedules `SuggestionEngine.retrain()`. Coalesced on a 3s timer that cancels
any pending retrain: deleting twenty rows costs one training pass, not twenty.

### Recording is gated on suggestions being enabled

`BrowserWindowController.webView(_:didFinish:)` guards history recording with
`SuggestionEngine.shared.isEnabled`. Turning off new-tab suggestions therefore stops
history collection entirely, and the new screen would sit empty with no explanation.

This spec **does not change that gate.** Removing it would silently start logging
browsing history for someone who had opted out, which is not a change to make on their
behalf. Instead the screen's empty state says so plainly and points at the setting:

> History isn't being recorded. Turn on Tools → New Tab Suggestions → Show
> Suggestions to start recording.

If the user would rather decouple recording from suggestions, that is a separate,
deliberate decision.

---

## Files

**New**
- `Sources/SessionStore.swift`
- `Sources/HistoryWindow.swift`

**Modified**
- `AppDelegate.swift` — menu items, launch restore, terminate flush, snapshot/restore, ⌘Y
- `BrowserWindowController.swift` — title recording, schedule session save
- `HistoryStore.swift` — `title`, `setTitle`, `remove(ids:)`, `.historyDidChange`
- `CLAUDE.md` — the three notes flagged above

## Testing

No test target; logic is proven with throwaway assert harnesses compiled against the
files under test, per CLAUDE.md. Pure seams to cover:

- `SessionSnapshot.build` — private exclusion, new-tab exclusion, empty-window drop,
  group and tab ordering
- `SessionStore` round-trip with an injected `fileURL`, including a missing file
- `HistoryGrouping.sections` — boundary behaviour at midnight, the 7-day edge, ordering
- `HistoryStore.remove(ids:)` / `setTitle` with an injected `fileURL`
- `Visit` decoding of a pre-`title` JSON file

Then `./build.sh` for a clean compile and signature. GUI launch is verified by the
user: `open -ngj` is inconclusive in the agent sandbox and `pkill` is blocked there.
