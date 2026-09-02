# Password manager

A built-in password manager for Rocket: Chrome's save-and-autofill workflow, with a
vault that is never decryptable without Touch ID or the macOS login password, and CSV
import from Apple Passwords, Chrome/Google and Firefox.

Read `CLAUDE.md` first. Everything below assumes its architecture section.

Decisions already made with the user:

- **Unlock is macOS authentication**, not a separate master password. A Secure
  Enclave key gated on user presence wraps the vault key; a one-time recovery key is
  the only other way in.
- **Touch ID on every fill by default** ("Lock After: Immediately"), changeable to a
  timed unlock.
- **Autofill is a native dropdown** under the login field, fed by a detection script in
  an isolated content world.
- **Site and username index is readable without a prompt**; passwords never are.
- **Hardened runtime** is turned on in `build.sh`.

---

## 1. Threat model

What the design defends against, in order of how much it cost:

1. **Theft of the vault file** (backup, disk image, another Mac, a `file://` read from
   the new tab page, which has read access to the whole `Rocket/` support folder). The
   file holds ciphertext only. The vault key is wrapped by a Secure Enclave key that
   does not exist off this Mac, and by a 160-bit recovery key stretched with PBKDF2.
2. **Malware running as the user on this Mac.** It cannot obtain a password without the
   user approving a Touch ID / password dialog, because the enclave refuses to use the
   gated key without a fresh authentication (verified: key agreement fails with
   `LAError -1004` when interaction is not allowed). Hardened runtime stops it
   injecting a library into Rocket or attaching a debugger without root. It *can* read
   the index (site + username pairs) by loading the silent enclave key blob, which is
   accepted because `history.json` already exposes every site in plain text.
3. **A malicious page.** It never receives the account list (native panel), cannot call
   the bridge (handler lives in an isolated `WKContentWorld`), cannot trigger a fill
   (fills need a click in native UI), and a look-alike domain gets no accounts
   (matching is by registrable domain).

Out of scope, stated so nobody assumes otherwise: root or a compromised macOS; a Touch
ID prompt the user approves for an app that is not Rocket (the dialog names the app);
copies the Swift runtime makes of secret bytes while a fill is in flight (zeroing is
best-effort — hardened runtime is the real barrier); the password once it sits in the
page's DOM (the site has to receive it).

Why not the keychain: an ad-hoc-signed binary gets `errSecMissingEntitlement` from the
data-protection keychain and from `SecKeyCreateRandomKey` with
`kSecAttrTokenIDSecureEnclave`, and adding `keychain-access-groups` to an ad-hoc
signature gets the process SIGKILLed by AMFI. CryptoKit's
`SecureEnclave.P256.KeyAgreement.PrivateKey` needs no entitlement, returns a
`dataRepresentation` blob that only this Mac's enclave can use, and honours a
`SecAccessControl`. All of this was measured on the target machine (M2, macOS 27).

---

## 2. Key hierarchy and file format

`~/Library/Application Support/Rocket/passwords.vault`, JSON, mode 0600, written
atomically.

```
K   vault key (random 256-bit)            → encrypts secrets
Ki  index key (random 256-bit)            → encrypts the index

K   wrapped by  enclave key G  (SecAccessControl: .privateKeyUsage + .userPresence)
K   wrapped by  KEK = PBKDF2-HMAC-SHA256(recoveryKey, salt, 1_000_000)
Ki  wrapped by  enclave key S  (no access control: silent on this Mac)
Ki  wrapped by  K              (so recovery restores the index as well)
```

Enclave wrap (ECIES-style, all CryptoKit): generate ephemeral P-256 key E; shared =
ECDH(E.private, enclaveKey.public); wrapKey = HKDF-SHA256(shared, salt: E.public,
info: "rocket.vault.wrap"); sealed = AES-256-GCM(wrapKey, K). Stored: enclave key
blob, E.public (raw), sealed (combined nonce‖ciphertext‖tag). Unwrap loads the blob
with an `LAContext`, recomputes shared with the enclave's private half, and opens.

Every AES-GCM seal carries a distinct additional-authenticated-data string
(`rocket.vault.v1.secrets`, `.index`, `.wrap.gated`, `.wrap.silent`, `.wrap.recovery`,
`.indexkey`) so blobs cannot be swapped between slots.

```swift
struct VaultFile: Codable {
    let version: Int                      // 1
    var gated: EnclaveWrap                // K
    var silent: EnclaveWrap               // Ki
    var recovery: RecoveryWrap            // K
    var indexKeyUnderVaultKey: Data       // Ki sealed with K
    var index: Data                       // VaultIndex sealed with Ki
    var secrets: Data                     // VaultSecrets sealed with K
    var modified: Date
}
struct EnclaveWrap: Codable  { let keyBlob: Data; let ephemeralPublicKey: Data; let sealed: Data }
struct RecoveryWrap: Codable { let salt: Data; let iterations: Int; let sealed: Data }

struct PasswordEntry: Codable, Equatable {   // the index: never holds a secret
    let id: UUID
    var host: String        // lowercased, port kept when non-default ("localhost:3000")
    var url: String?        // as saved or imported, for display and "open site"
    var username: String
    var title: String?
    var created: Date
    var modified: Date
    var lastUsed: Date?
}
struct VaultIndex: Codable   { var entries: [PasswordEntry] }
struct PasswordSecret: Codable { var password: String; var notes: String?; var otpAuth: String? }
struct VaultSecrets: Codable { var byID: [UUID: PasswordSecret] }
```

`otpAuth` is preserved from Apple's CSV so an import loses nothing; Rocket does not
generate codes from it.

**Recovery key**: 20 random bytes in Crockford base32 (`0-9 A-Z` minus `I L O U`),
shown as 8 groups of 4, e.g. `7K3M-Q2XN-…`. `RecoveryKey.normalize` strips separators
and case before decoding, so a key typed with spaces or lowercase still works.

### Testability seam

The enclave is behind a protocol so the whole crypto path runs in an assert harness
with software keys:

```swift
protocol EnclaveProvider {
    var isAvailable: Bool { get }
    func makeKey(gated: Bool) throws -> Data                       // returns the blob
    func publicKey(for blob: Data) throws -> Data
    func sharedSecret(blob: Data, ephemeralPublic: Data, context: LAContext?) throws -> SharedSecret
}
```

`SecureEnclaveProvider` is the real one. `SoftwareEnclaveProvider` (test-only, lives
in the harness) keeps P-256 keys in a dictionary keyed by a fake blob. `VaultCrypto`
(pure static functions: `wrap`, `unwrap`, `sealRecovery`, `openRecovery`, `seal`,
`open`, `deriveKEK`) never touches the singleton.

---

## 3. `PasswordStore` (`Sources/PasswordStore.swift`)

Singleton with an injectable `init(fileURL:enclave:authenticator:)`, mirroring the
other stores. Owns the decrypted **index** in memory (loaded silently on first access
via the silent enclave key) and never keeps secrets beyond one operation unless the
lock policy says so.

```swift
var isSetUp: Bool
var entries: [PasswordEntry]                                  // the index
func entries(for host: String) -> [PasswordEntry]              // SiteMatcher, exact host first
func setUp() throws -> String                                  // creates vault, returns recovery key
func withSecrets<T>(reason: String, _ body: (inout VaultSecrets) throws -> T) throws -> T
func password(for id: UUID, reason: String) throws -> SecureString
func add(_ entry: PasswordEntry, secret: PasswordSecret, reason: String) throws
func update(_ entry: PasswordEntry, secret: PasswordSecret?, reason: String) throws
func delete(ids: Set<UUID>, reason: String) throws
func markUsed(id: UUID)                                        // index only: no prompt
func lockNow()
func replaceRecoveryKey(reason: String) throws -> String
func restore(recoveryKey: String) throws                       // rebinds to this Mac's enclave
```

`withSecrets` is the only path to K. It asks the `Authenticator` for an `LAContext`
that has just passed `.deviceOwnerAuthentication` with `reason` as the dialog text
("Fill your password for github.com"), unwraps K with that context, decrypts, runs
`body`, re-seals if the body mutated, then zeroes.

```swift
protocol Authenticator {
    func authenticate(reason: String, completion: @escaping (Result<LAContext?, Error>) -> Void)
}
```

`LocalAuthenticator` evaluates `.deviceOwnerAuthentication` (Touch ID with the macOS
password as the system's own fallback). The harness's `StubAuthenticator` returns
`nil`, which the software enclave ignores. User cancellation surfaces as
`LAError.userCancel` and callers treat it as "do nothing", never as a failure alert. Every mutation saves and posts
`.passwordsDidChange`, the `BookmarkStore` rule.

**Lock policy** — `PasswordsLockAfter` (Int seconds, default 0):

- `0` (Immediately): K is dropped when `withSecrets` returns. Every fill, save,
  reveal, copy, edit, import and export is one Touch ID.
- `300 / 900 / 3600`: K is kept in a `SecureBytes` with a last-use stamp and reused
  without a prompt inside the window. A timer, `NSWorkspace.willSleepNotification`,
  `sessionDidResignActiveNotification`, the `com.apple.screenIsLocked` distributed
  notification, `applicationWillTerminate` and Lock Now all drop it.

The `LAContext` uses `touchIDAuthenticationAllowableReuseDuration = 0` and a fresh
context per operation, so the enclave's own gate is what enforces "every fill", not
app logic. If the enclave does not honour the pre-evaluated context it prompts again
with the system's wording; the plan's first task verifies which happens on this Mac.

**Secrets in memory**: `SecureBytes` (a final class over `[UInt8]` that `memset_s`
zeroes in `deinit`) and `SecureString` (same, with `withString { }` for the ms a
`String` is unavoidable). The decrypted `VaultSecrets` JSON `Data` is `resetBytes`
before release.

**No Secure Enclave** (Intel Mac without T2): `setUp` throws and the UI says Rocket
Passwords needs a Mac with a Secure Enclave. No software fallback — it would silently
downgrade the guarantee this feature exists for.

---

## 4. Setup and recovery

Setup runs the first time any of these needs the vault: Save in the bubble, Add or
Import in the manager. A sheet on the front window:

1. One paragraph: what unlocks the vault (Touch ID or your Mac password), what the
   recovery key is for.
2. Continue → `setUp()`: generate K and Ki, create both enclave keys, wrap, then
   **immediately unwrap K with the gated key** (one Touch ID) to prove the round trip
   before anything is written. A vault that could never be opened must not be saved.
3. The recovery key in a selectable monospaced field with Copy, a checkbox "I have
   saved this key somewhere safe", and Done disabled until it is checked.

Tools → Passwords → **Change Recovery Key…** (Touch ID) regenerates it.
**Restore from Recovery Key…** appears instead of the normal items when the file
exists but the *silent* enclave blob fails to load — the one check that needs no
prompt, and a blob from another enclave always fails it (new Mac, erased Mac). It
asks for the key,
unwraps K, then Ki via `indexKeyUnderVaultKey`, creates fresh enclave keys and
rewrites every wrap.

---

## 5. Autofill (`Sources/PasswordAutofill.swift`, `Sources/PasswordDropdown.swift`)

### The page side

One `WKUserScript`, `.atDocumentEnd`, all frames, in
`WKContentWorld.world(name: "RocketPasswords")`. Added from `ContentBlocker.apply`
next to PrivacyShield, because `apply` wipes user scripts and a toggle must never
strip it. The message handler is registered with `add(_:contentWorld:name:)` under
the name `rocketPasswords`, once per configuration, right where `NewTabPageBridge` is
registered and for the same reason: popups share the opener's content controller, so
the bridge is a singleton that routes on `message.webView`, never a captured
controller. `windowWillClose` must not remove it.

What the script does:

- **Detect** visible `input[type=password]` elements. For each, the username field is
  the nearest preceding visible text/email/tel input in the same form (or, with no
  form, the nearest common ancestor holding at most one other text field), preferring
  `autocomplete` values `username` and `email`. `autocomplete=new-password` or two
  password fields in one form marks a **sign-up** form. A form with a username field
  and no password field is a **username-only** step (Google, Microsoft). Every field
  gets an id in a `WeakMap`; Swift only ever speaks in those ids.
- **Report** focus, blur, movement (scroll/resize, throttled) and rectangles in CSS
  pixels. In a same-origin subframe the rectangle is offset through
  `window.frameElement`; in a cross-origin one it is `null`, and Swift anchors the
  dropdown to the toolbar key button instead.
- **Keys**: only while Swift has called `setPanelVisible(true)`, `ArrowUp`,
  `ArrowDown`, `Enter` and `Escape` on the focused field are `preventDefault`ed and
  reported. Anything else hides the panel.
- **Fill**: `fill({fieldID, username, password})` sets values through the native
  `HTMLInputElement.prototype.value` setter and dispatches `input` and `change`, which
  is what makes React and Vue notice. `fillUsernameOnly` and `fillActive` (the toolbar
  fallback: fills the best form on the page) reuse it.
- **Submit capture**: on `submit` (capture phase), a click on a submit button inside
  the form, or Enter in a login field, post `credentialsSubmitted {host, username,
  password}` or, for a username-only step, `usernameSubmitted {host, username}`. A
  `MutationObserver` posts `formVanished` when the captured password field leaves the
  DOM with a value, which is how single-page logins get a save prompt. Duplicate posts
  for the same values are suppressed.

Messages Swift accepts: `fieldFocused`, `fieldBlurred`, `fieldMoved`, `key`,
`credentialsSubmitted`, `usernameSubmitted`, `formVanished`. Calls into the page go
through `callAsyncJavaScript(_:arguments:in:in:)` with the frame from
`message.frameInfo`, so a password is passed as an argument and never spliced into
source text.

### The native side

`PasswordAutofillController`, one per `BrowserWindowController`, owns:

- **`PasswordDropdown`** — an `NSPanel` child window styled like
  `SuggestionsDropdown` (same material, row height, highlight). Rows: one per account
  (username, plus the host when matched by parent domain), then "Use Strong Password"
  on sign-up forms, then "Manage Passwords…". On an `http:` page a disabled caption row
  says "Not secure". No accounts and not a sign-up form → nothing is shown. With
  no vault yet the same rules apply: a sign-up form still offers a generated
  password, and saving it is what triggers setup.
  Position: the CSS rectangle × `webView.magnification`, flipped into the web view's
  coordinates, converted to screen the way `SuggestionsDropdown.show` does.
- **Fill flow**: row click or Enter → `PasswordStore.password(for:reason:)` (Touch
  ID per policy) → `fill` in that frame → `markUsed`. On a username-only step the
  username fills with no prompt at all, since it comes from the index. Filling
  requires the frame's registrable domain to match the page's; anything else is
  refused.
- **Toolbar key button** (`rocket.passwords`, SF Symbol `key.fill`, custom `NSButton`
  view like the downloads item so a popover can anchor to it). Click → menu of the
  site's accounts (`fillActive`), "Manage Passwords…". It is also where the save
  bubble hangs.

`PasswordGenerator.make()` (pure): 20 characters drawn with
`SystemRandomNumberGenerator` from upper, lower, digits and `!@#$%^&*-_+=?`, with at
least one of each class guaranteed by construction, not by retry.

`SiteMatcher` (pure, `Sources/SiteMatcher.swift`): `registrableDomain(of:)` takes the
last two labels, or three when the TLD is two letters and the second-level label is
one of `co com net org gov edu ac or ne go gob mil` (covers `co.uk`, `com.au`,
`co.jp`). IP addresses and `localhost` match exactly. `matches(entryHost:pageHost:)`
strips a leading `www.` on both sides.

---

## 6. Saving (`Sources/PasswordSaveBubble.swift`)

A `credentialsSubmitted` message becomes the tab's `pendingCredential` (host,
username, `SecureString` password, captured-at, `filledByRocket`). It is shown, not
acted on, at the next `didFinish` in that tab or on `formVanished`, and discarded
after 60 s, on tab close, or when a newer submit replaces it. A `usernameSubmitted`
from the previous step is remembered for two minutes so a two-page login saves with
its username.

```swift
enum SavePolicy {
    enum Decision { case ignore, offerSave, offerUpdate(PasswordEntry) }
    static func decide(host: String, username: String, filledByRocket: Bool,
                       existing: [PasswordEntry], neverSave: Set<String>,
                       isPrivate: Bool) -> Decision
}
```

Pure, therefore tested. Incognito → ignore. Host on the never list → ignore. No entry
for host+username → offer save. Entry exists and Rocket filled it → ignore. Entry
exists and the user typed it → offer update (Rocket cannot compare without unlocking;
choosing Update unlocks, and an identical password just bumps `lastUsed`).

The bubble is an `NSPopover` on the key button: "Save password for github.com?",
editable username, password as dots with a reveal toggle, **Save**, **Never**,
**Not Now**. Save runs setup first if there is no vault, then one Touch ID. Never adds
the exact host to `PasswordsNeverSaveHosts` in UserDefaults — plain text on purpose:
it has to be consulted while the vault is locked, and it reveals less than history.
Chrome stores the same list unencrypted.

Known imperfection, accepted: a failed login that reloads the form still gets a
bubble. Not Now costs one click.

---

## 7. Manager window (`Sources/PasswordsWindow.swift`)

`PasswordsWindowController.shared`, opened by Tools → Passwords → Show Passwords
(⌥⌘P), handled by `AppDelegate` so it works with no browser window. Layout, same
bones as `HistoryWindow`: search field, view-based `NSTableView` (Site, Username, Last
Used), detail pane for the selection: site (click opens it in a new tab), username,
password as `NSSecureTextField` with Reveal/Hide and Copy, notes, OTP line when present
(read-only). Edit in place → Save (Touch ID). `+` adds an entry. ⌫ and a context menu
delete, after confirmation. Bottom buttons: Import…, Export….

Search is a case-insensitive substring over host, username and title, listing straight
from the index — no prompt to browse. Before setup the table is replaced by an empty
state ("No passwords saved yet") with Add and Import buttons; either runs setup first. Reveal, Copy, Save and Delete each go through
`withSecrets`. Reveal hides itself after 30 s. Copy writes with
`org.nspasteboard.ConcealedType` alongside the string and clears the pasteboard after
60 s if its `changeCount` is still ours.

---

## 8. Import and export (`Sources/PasswordImport.swift`)

`CSVParser.parse(_:) -> [[String]]`: RFC 4180 — quoted fields, doubled quotes, commas
and newlines inside quotes, CRLF, a leading UTF-8 BOM. Pure.

`PasswordImport.parse(csv:) -> ImportResult` maps columns by header name,
case-insensitively:

| field    | accepted headers                                  |
|----------|---------------------------------------------------|
| url      | `url`, `URL`, `website`, `login_uri`, `formActionOrigin` |
| username | `username`, `Username`, `login`, `user`           |
| password | `password`, `Password`                            |
| title    | `name`, `Title`, `title`                          |
| notes    | `note`, `notes`, `Notes`, `extra`                 |
| otpAuth  | `OTPAuth`, `otpauth`, `totp`                      |

That covers Apple Passwords (`Title,URL,Username,Password,Notes,OTPAuth`),
Chrome/Google (`name,url,username,password,note`) and Firefox
(`url,username,password,httpRealm,formActionOrigin,…`). A URL without a scheme gets
`https://`. Rows with no password or no usable host are counted as unreadable, not
dropped silently.

`PasswordImport.merge(_:into:) -> MergePlan` is pure: same host+username+password →
skipped; same host+username, different password → updated; otherwise added.

Flow: Tools → Passwords → Import from CSV… → `NSOpenPanel` (CSV) → parse → setup if
needed → `withSecrets` (one Touch ID) → apply plan → alert "Imported 143, updated 5,
skipped 12 duplicates, 2 rows unreadable" → "Move the CSV to the Trash?" via
`FileManager.trashItem`, with the note that the Trash is not a secure erase.

Export: Touch ID → alert "The file will contain every password in plain text" →
`NSSavePanel` → Apple's column set, quoted per RFC 4180.

---

## 9. Menus and settings

Tools → **Passwords** submenu (`passwordsMenu`, rebuilt in `menuNeedsUpdate`):

- Show Passwords… ⌥⌘P
- Import from CSV…
- Export to CSV…
- Lock Now
- ——
- Autofill Passwords (toggle, `PasswordsAutofill`, default on — off hides the dropdown;
  the script stays for the key button and save capture)
- Offer to Save Passwords (toggle, `PasswordsOfferToSave`, default on)
- Lock After ▸ Immediately / 5 Minutes / 15 Minutes / 1 Hour (tags, like scan policy)
- ——
- Change Recovery Key… / Restore from Recovery Key… (whichever applies)

Checkmarks and enabled states live in `validateMenuItem` on `AppDelegate`, the existing
pattern. Both toggles read `?? true`; `PasswordsLockAfter` reads `?? 0`.

---

## 10. Build hardening

`build.sh` signs with `--options runtime --entitlements Entitlements.plist` in both the
build and `--install` paths. `Entitlements.plist` (new, repo root, next to
`Info.plist`) holds only `com.apple.security.device.camera`,
`com.apple.security.device.audio-input` and
`com.apple.security.personal-information.location` — under hardened runtime these are
required for the camera, microphone and location features the existing usage strings
already describe. Nothing else: restricted entitlements get an ad-hoc binary killed.
Verified with a probe binary that this combination runs. `codesign -d -vv` must show
`flags=0x10000(runtime)` after a build.

---

## 11. Files

**New**
- `Sources/PasswordVault.swift` — types in §2, `VaultCrypto`, `RecoveryKey`,
  `EnclaveProvider`, `SecureEnclaveProvider`, `SecureBytes`, `SecureString`
- `Sources/PasswordStore.swift`
- `Sources/SiteMatcher.swift`
- `Sources/PasswordAutofill.swift` — script source, bridge, `PasswordAutofillController`,
  `SavePolicy`, `PasswordGenerator`
- `Sources/PasswordDropdown.swift`
- `Sources/PasswordSaveBubble.swift`
- `Sources/PasswordsWindow.swift`
- `Sources/PasswordImport.swift` — `CSVParser`, `PasswordImport`, `PasswordExport`
- `Entitlements.plist`

**Modified**
- `BrowserWindowController.swift` — key toolbar item, bridge registration, autofill
  controller hooks in `didFinish`, `didStartProvisionalNavigation`, `windowWillClose`
- `AppDelegate.swift` — Passwords submenu, actions, validation, lock notifications
- `ContentBlocker.swift` — re-add the autofill script in `apply`
- `build.sh` — hardened runtime + entitlements
- `CLAUDE.md`, `README.md`

## 12. Testing

Assert harnesses per `CLAUDE.md`, compiled against the files under test:

- `VaultCrypto` round trips with `SoftwareEnclaveProvider`: gated and silent wraps,
  recovery wrap, wrong recovery key fails, AAD mismatch fails, tampered ciphertext fails
- `RecoveryKey` generate → normalize (lowercase, spaces, dashes) → decode
- `PasswordStore` with an injected `fileURL` and software enclave: setup, add, update,
  delete, `markUsed` without unlocking, lock timer behaviour, `restore(recoveryKey:)`
  producing a file that opens with new enclave keys
- `SiteMatcher`: `co.uk`, `com.au`, IPs, `localhost:3000`, `www.` on either side
- `CSVParser`: quotes, doubled quotes, embedded newlines, CRLF, BOM
- `PasswordImport.parse` against a real Apple Passwords header row, a Chrome export and
  a Firefox export; `merge` skip/update/add
- `SavePolicy.decide`: every branch in §6
- `PasswordGenerator`: length and character-class guarantees

Then `./build.sh`, and `codesign -d -vv` for the runtime flag. Touch ID, the in-page
script and the dropdown are verified by the user on real sites (a plain form, Google's
two-step login, a React app): `open -ngj` is inconclusive in the agent sandbox.

## 13. Implementation order

1. `PasswordVault` + `PasswordStore` + `SiteMatcher` with harnesses, then a spike in
   the app: setup sheet and one Touch ID round trip, to confirm the pre-evaluated
   `LAContext` is honoured on this machine.
2. Build hardening.
3. Manager window, import, export.
4. Detection script, dropdown, fill, key button.
5. Save bubble and `SavePolicy`.
6. `CLAUDE.md` and `README.md`.
