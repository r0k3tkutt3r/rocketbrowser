# Rocket 🚀

A small, fast personal browser for macOS built on Safari's WebKit engine (WKWebView).
Pure Swift + AppKit, ~13,000 lines, no Xcode project, no dependencies — builds in a few
seconds with `swiftc`.

## Features

- Tabs — native macOS window tabs (⌘T / ⌘W, ⌘1–⌘9 to jump, drag to reorder)
- New tab page — local start page with customizable wallpaper
- Quad-stream download chunking for a ~2x speed improvement
- Link preconnect — hovering a link opens its connection before you click, as does landing on a sign-in redirect
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
- Value watching — watch a price on a page and get told when it moves ([details](#watching-a-value))
- Password manager — Secure Enclave vault, Touch ID autofill, CSV import ([details](#passwords))
- Downloads viewer — progress bar, speed, VirusTotal scanning (hash-only by default)
- Tab activity — what each tab costs in CPU and memory, asked of the kernel rather than guessed
- Private windows — ⇧⌘N with ephemeral data store
- Persistent logins — via WebKit's persistent cookie store
- Back/forward — toolbar buttons, ⌘[ / ⌘], and two-finger swipe
- Popup handling — `target=_blank` and `window.open` open as tabs
- Page zoom — ⌘+ / ⌘− / ⌘0
- Web Inspector — right-click → Inspect Element, plus a Develop menu (⌥⌘I, console, view source, hard reload)
- Default browser capable — register as http/https handler
- No backspace navigation — Delete key doesn't trigger "go back"

## Passwords

Rocket has its own password manager: Chrome's workflow with Safari's lock.

Sign in to a site and Rocket offers to save. Click a login field and a small native
list of your accounts for that site drops down — pick one, confirm with Touch ID, and
it fills **and signs you straight in**, the way Safari does. Sign-up forms offer a
generated 20-character password instead, and are never submitted for you, since you
still have the rest of the form to fill in. The key button in the toolbar does the same
job on pages where field detection comes up empty.

Signing in for you means finding the right control, not just pressing Return: Rocket
prefers the form's real submit button, will accept one labelled like signing in, and
refuses ones that read like "Forgot password", "Show", or "Create account" — falling
back to submitting the form itself, and finally to a Return keypress for single-page
logins that have no form element. If a site does something it doesn't like — a CAPTCHA,
a "remember me" box you want to tick first — turn off Tools → Passwords → **Sign In
After Filling** and it will fill only.

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

Passwords are never filled on an unencrypted `http://` page — the credential would
cross the network readable by anyone on the path, so Rocket declines and says so.
Loopback addresses like `localhost:3000` are exempt, since there is no network hop.

**What the web page can see:** nothing. The detection script runs in an isolated
JavaScript world that pages cannot see into or call, the account list is drawn in a
native macOS panel rather than in the page, nothing is ever filled without your click,
and a site is only offered credentials saved under its own registrable domain — so a
look-alike domain gets nothing, and neither does a free account on a shared host like
`attacker.github.io`. Synthetic events are ignored, so a page cannot fake the keystrokes
that would drive the panel into filling itself.

The app is signed with the hardened runtime, which stops other processes injecting code
into Rocket or attaching a debugger to it. With a Developer ID certificate in the
keychain `./build.sh` uses it automatically, which is what turns on library validation —
only Apple-signed or same-team code can load into the process. Without that certificate
the build falls back to an ad-hoc signature and says so; ad-hoc has no team, so that
barrier is not really there and anyone can re-sign a modified copy. Either way, the
barrier your passwords actually rest on is the Secure Enclave gate, which no signature
gets past.

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

## Watching a value

Select a price on a page, then Tools → Watches → **Watch This Value…** and pick how often
to check: hourly, every six hours, or daily. Rocket reloads the page on its own, reads the
same element, and marks the watch when the value moves. A change puts a count on the Dock
icon and an arrow beside the value in the Watches menu. Each watch's own submenu holds the
old value, when it was last checked, and items to open the page, recheck it now, or stop
watching. Opening the menu counts as having seen it and clears the badge.

If something moved while Rocket was closed, the next launch says so in a small panel in
the corner of the window: the new value, what it used to be, and a click to open the page.
Each change is announced once, so quitting and reopening doesn't hand you the same news
again, and opening the Watches menu instead is enough to have seen it.

Numbers are compared as numbers, so `$30` becoming `30.00 USD` is not news, while
`$1,299.00` becoming `$1,199.00` is a ▼ and a difference of $100. European formats read
correctly: `1.299,00 €` is the same money as `$1,299.00`. Anything that doesn't parse as a
number is compared as text, which is what catches "In stock" turning into "Sold out".

The check loads the page in a web view you never see, using your normal cookies, so a site
that shows you a member price shows Rocket the same one. Loading it rather than fetching
the HTML is deliberate: most prices are written in by script and aren't in the markup at
all. For the same reason the value is read only once it stops changing — a page that fills
its price in a second late hands you "loading…" if you read too early. The element is
pinned when you create the watch, and Rocket refuses the watch outright if it can't find
its way back to exactly what you selected, rather than watch the wrong thing for a week.

Checks run one at a time and never faster than hourly. Watching is offered in normal
windows only; a private window has nothing it should be writing down.

## Distributing a build

```bash
./build.sh              # Developer ID signature + hardened runtime
./build.sh --notarize   # submit to Apple, staple the ticket, verify with spctl
```

Builds are Apple Silicon only — an Intel Mac cannot run them.

Notarization needs credentials stored once:

```bash
xcrun notarytool store-credentials rocket-notary --apple-id "you@example.com" --team-id "HWWPT38672" --password "<app-specific password>"
```

The app-specific password is generated, not chosen: sign in at
[account.apple.com](https://account.apple.com) with the Apple ID on the developer team,
go to **Sign-In and Security → App-Specific Passwords**, and create one. It looks like
`abcd-efgh-ijkl-mnop` and is shown once. `store-credentials` puts it in the keychain
under that profile name, so it is needed only the first time.
Signing with Developer ID alone is not enough — since macOS 10.15 an un-notarized
download is refused with "Apple cannot check it for malicious software". Stapling
writes the ticket into the bundle so it also passes with no network.

Nothing secret ships in the bundle: it contains only `Info.plist`, `PkgInfo`, the
binary and the generated icon. The VirusTotal key lives in your keychain, so anyone
you give the app to simply sees download scanning switched off until they add
their own key.

## Customizing

```bash
# Change the homepage / new-tab page (default: google.com)
defaults write com.kushmodi.rocket Homepage "https://duckduckgo.com"
```

Search engine: edit `URLResolver` in `Sources/Views.swift`.

