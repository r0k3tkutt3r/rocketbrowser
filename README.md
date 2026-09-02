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
- Password manager — Secure Enclave vault, Touch ID autofill, CSV import ([details](#passwords))
- Downloads viewer — progress bar, speed, VirusTotal scanning (hash-only by default)
- Private windows — ⇧⌘N with ephemeral data store
- Persistent logins — via WebKit's persistent cookie store
- Back/forward — toolbar buttons, ⌘[ / ⌘], and two-finger swipe
- Popup handling — `target=_blank` and `window.open` open as tabs
- Page zoom — ⌘+ / ⌘− / ⌘0
- Web Inspector — right-click → Inspect Element
- Default browser capable — register as http/https handler
- No backspace navigation — Delete key doesn't trigger "go back"

## Passwords

Rocket has its own password manager: Chrome's workflow with Safari's lock.

Sign in to a site and Rocket offers to save. Click a login field and a small native
list of your accounts for that site drops down — pick one, confirm with Touch ID, and
it fills. Sign-up forms offer a generated 20-character password. The key button in the
toolbar does the same job on pages where field detection comes up empty.

**How it's protected.** Everything lives in `passwords.vault`, encrypted with
AES-256-GCM. The key that opens your passwords is wrapped by a Secure Enclave key
created to require user presence, so *every* use of it needs Touch ID or your Mac
login password — enforced by the enclave hardware, not by Rocket's own code. The blob
that key is stored as is useless on any other Mac. There is no "unlocked" state on
disk and, by default, none in memory either: the setting is **Lock After →
Immediately**, so each fill, reveal, copy or save authenticates on its own. You can
relax that to 5 minutes, 15 minutes or an hour; either way the key is dropped when the
Mac sleeps, the screen locks, you switch users, or Rocket quits.

At setup you get a **recovery key** once — 32 characters, shown a single time. It is
the only way into the vault on another Mac or after this one is erased, so write it
down. Rocket cannot show it to you again, and cannot recover the vault without it.

**What Rocket can read without asking:** the list of sites and usernames, and nothing
else. That is deliberate — it's what lets the account list appear under a login field
before you authenticate, exactly as Chrome and Safari do. That index is encrypted too,
and unreadable on any other Mac; the reasoning is that your history file already
records every site you visit. Passwords, notes and one-time-code seeds are never
readable without authenticating.

**What the web page can see:** nothing. The detection script runs in an isolated
JavaScript world that pages cannot see into or call, the account list is drawn in a
native macOS panel rather than in the page, nothing is ever filled without your click,
and a site is only offered credentials saved under its own registrable domain — so a
look-alike domain gets nothing, and neither does a free account on a shared host like
`attacker.github.io`. Synthetic events are ignored, so a page cannot fake the keystrokes
that would drive the panel into filling itself.

The app is signed with the hardened runtime, which stops other processes injecting code
into Rocket or attaching a debugger to it. One honest caveat: the signature is ad-hoc,
and re-signing ad-hoc takes no key, so malware that can already write to the app bundle
could produce an unhardened copy. That is a real limit, and only a Developer ID
signature with notarization would close it. The barrier your passwords actually rest on
is the Secure Enclave gate, which no amount of re-signing gets past.

**Import and export.** Tools → Passwords → Import from CSV… reads exports from Apple
Passwords, Chrome/Google and Firefox, mapping the columns by name so you don't have to
say which is which. Duplicates are skipped, changed passwords update in place, and
Rocket offers to move the CSV to the Trash afterwards (saying plainly that the Trash is
not a secure erase). Export writes Apple's column set, after a warning that the file
holds every password in plain text.

**Where things are:** Tools → Passwords holds the manager (⌥⌘P), import, export, Lock
Now, the autofill and save toggles, Lock After, and Change/Restore Recovery Key.

Note on Apple's own passwords: Apple does not expose Passwords/iCloud Keychain autofill
to third-party browsers on macOS — it's wired into Safari, not into WKWebView, and
there is no public API for it through macOS 26/27. Importing the CSV is the way across.

## Customizing

```bash
# Change the homepage / new-tab page (default: google.com)
defaults write com.kushmodi.rocket Homepage "https://duckduckgo.com"
```

Search engine: edit `URLResolver` in `Sources/Views.swift`.

