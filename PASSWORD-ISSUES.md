# Password manager: open issues

These are what remain from the adversarial review of the password manager on
2026-11-06 (commit `c3c522d`). Each finding was reproduced twice, once by the agent
that found it and once in a rerun. The two critical findings, a forged vault key and an
index rewritten to point a password at another site, are fixed in `7d11b38`, and so is
"one damaged index byte defeats the recovery key". Everything below is still open.

The repro harnesses are untracked files in three review worktrees under
`.claude/worktrees/`. Delete those worktrees and the harnesses go with them.

- `S` is `agent-a1b642213ec2cbf81` (saving, import, matching)
- `P` is `agent-a35cb96274102e44f` (hostile pages, plus the vault fix's attack tests in `scratch/fix/`)
- `V` is `agent-a9bbf16e5bf76cdf1` (vault format and state)

## High

### 1. Tenants on shared hosting are treated as one site

A password saved on `victim.<suffix>` is listed, filled and, by default, submitted on
`attacker.<suffix>`. Anyone can register the second for free. Affected suffixes
include `replit.app`, `lovable.app`, `streamlit.app`, `framer.app`, `vercel.dev`,
`on.aws`, regional `s3.*.amazonaws.com` and `execute-api.*.amazonaws.com`, regional
`elasticbeanstalk.com`, and every `blogspot` country variant (`blogspot.de`,
`blogspot.co.uk`, ...). `github.io` is listed and works correctly. Measured against a
full copy of the Public Suffix List, 3,101 rules in its private (hosting) section are
merged this way.

- Repro: `./scratch/p2/t` in `P`, and `harness/t4/t4` in `S`.
- Output: `victim.replit.app | attacker.replit.app -> matches: true`, and
  `page evil.blogspot.de would list: ["victim.blogspot.de (alice)"]`.
- Root cause: `Sources/SiteMatcher.swift`. `sharedSuffixes` is a hand list, and the tail
  loop only recognises a listed suffix as a contiguous literal. Anything unlisted falls
  back to the last two labels.
- Also reachable: `WebAuthn.isValid` uses the same function, so an RP id like `on.aws` or
  `amazonaws.com` should be accepted (read in source, not run). `SavePolicy.decide`
  also lets a Rocket fill on one tenant suppress the save on another (run in `S`).
- Fix direction: match against the Public Suffix List's private section rather than a
  hand list. When in doubt be narrow, since too narrow only hides an account.

### 2. Overlapping vault writes lose saves while reporting success

`mutate` and `replaceRecoveryKey` take a snapshot of `file` and `index` when they
are called. They then write that snapshot back, no matter what landed in between. Two
saves close together keep only the later one. A save that overlaps a recovery-key
rotation can undo the rotation, so the key you were just shown doesn't open the vault
and the old one still does.

- Repro: `.scratch/vh T2`, `T1b`, `T1c` and `T1d` in `V`, `harness/t2/t2 <dir>` in
  `S`, and `./scratch/race/t` in `P`.
- Output: `completions: success() success()` with `hosts on disk : ["b.example"]`.
  After a rotation, `new key opens vault: false` and `OLD key opens vault: true`.
- Conditions: easiest when Lock After is above 0. It also happens on the default Lock
  After 0 if two Touch ID sheets are answered together.
- Root cause: `PasswordStore.mutate` and `PasswordStore.replaceRecoveryKey` capture
  state before their queue work and never rebase on it.
- Fix direction: serialise vault operations, or rebase each write on the current
  `file` on the main thread before sealing.

### 3. Rotating the recovery key doesn't revoke the old one

Rotation re-wraps the same vault key K under a new recovery key. An old recovery key plus
any older copy of the file, such as a Time Machine backup, still yields K, and K
opens today's file, including passwords saved after the rotation.

- Repro: `.scratch/vh T5` in `V`.
- Output: `pre-rotation backup + old key decrypts today's secrets: ["SAVED-AFTER-ROTATION", "pre"]`
- Root cause: `PasswordStore.replaceRecoveryKey` changes only `recovery`, never K.
- Fix direction: rotation generates a new K and re-seals the secrets under it.

## Medium

### 4. A pending setup can wipe a vault in use

`setUp` checks that no vault exists before it authenticates, then writes without
checking again. With two windows on the setup prompt, confirming the second replaces
the live vault with an empty one, and the first recovery key stops working.

- Repro: `.scratch/vh T4` in `V`.
- Output: `after B confirms : entries: []  disk: 0 entries`
- Fix direction: repeat the existence check at write time.

### 5. Two Rocket instances overwrite each other's saves

`load()` reads the file once, and writes never compare against disk. Instance B
writes its stale copy over instance A's save. The repo itself launches second
instances with `open -n`.

- Repro: `.scratch/vh T3` in `V`.
- Output: `hosts on disk: ["b.example"]`, where both hosts belong.
- Fix direction: a file lock, or compare the modification time before each write and
  reload on a mismatch.

### 6. A page can raise the account panel with no user action, where it chooses

Calling `focus()` from page script fires a `focusin` that the browser marks trusted,
so the `isTrusted` gate passes. The page controls the field's position and can use a
2 px field or one inside an `opacity:0` parent, which `isVisible` doesn't see. A fill
then lands in that hidden field, and the page reads it back.

- Repro: serve `scratch/js/www` on `127.0.0.1:8765` in `P`, then run
  `./scratch/js/t scratch/js/autofill.js http://127.0.0.1:8765/a.html`.
- Output: `fieldFocused` at the page-chosen `x = 123; y = 456`, and
  `page-world read of #pa.value: S3CRET-VALUE`.
- Limits: this only reaches the same site's accounts, and a password fill still needs
  Touch ID. Not run: whether a page can time the panel under the pointer, since
  `PasswordDropdown` fills on `mouseDown` (read in source). Username-only fills need no
  authentication.
- Root cause: `isVisible` and the `focusin` handler in `Sources/PasswordAutofill.swift`.
- Fix direction: require a recent trusted pointer or key event on that field, and
  check visibility up the ancestor chain.

### 7. Import and export lose or change data

- An import silently replaces a newer saved password with an older one for the same
  site and username, with no prompt and no backup. The summary only says "updated".
- Notes containing a Windows line ending (CRLF) aren't quoted on export, so on
  re-import the row splits and the OTP seed and the rest of the notes are lost.
- Export prefixes text such as `-----BEGIN KEY-----` with `'`, so it comes back changed.
- Two different passwords for one site and username in a single import keep only the
  last, and the drop isn't counted.
- Rows duplicated within one file resolve in the opposite direction from a duplicate
  of an existing entry.
- Repro: `.scratch/vh T12` in `V`, and `harness/t1/t1` in `S`.
- Root cause: `Sources/PasswordImport.swift` (merge plan, CSV writer) and the apply
  step in `Sources/PasswordFlows.swift`.

## Low

### 8. Editing an entry without revealing it erases its notes

The notes box starts empty until you reveal the entry, and Save always writes the box
back. Fixing a username therefore deletes the notes, backup codes included, and reports
success. The same should happen after the box is cleared on lock (read in source, not run).

- Repro: `.scratch/vui .scratch/uirun` in `V`.
- Output: `notes after a username-only edit: nil`
- Root cause: `Sources/PasswordsWindow.swift`, where `saveTapped` sends the notes field unconditionally.

### 9. The vault key can outlive a lock, and a shorter Lock After doesn't apply

An unlock already in flight when the Mac locks caches K afterwards. Separately,
lowering Lock After keeps the old timer running, so going from 1 hour to 5 minutes can
leave K cached for up to the hour.

- Repro: `.scratch/vh T10` in `V`.
- Output: `after in-flight op finished isUnlocked: true`, and
  `0.2 s Lock After chosen over 3600; 1 s later isUnlocked: true`.
- Root cause: `PasswordStore.cache` doesn't check for a lock since the unlock began,
  and the `lockAfter` `didSet` ignores non-zero changes.

### 10. A page can force the save capture with `requestSubmit()`

`form.requestSubmit()` fires a `submit` the browser marks trusted, so a page can
trigger `credentialsSubmitted` when it chooses. It can only use a password the user
typed or Rocket filled, but it picks the username.

- Repro: the same run as issue 6.
- Output: `credentialsSubmitted filledByRocket=1 ... username=victim@example.com`
- Root cause: the `submit` listener in `Sources/PasswordAutofill.swift`.

### 11. Imported URLs are stored as written

`javascript://example.com/...` and `https://bank.com@evil.io/` are kept verbatim as the
entry's URL. Only the stored value was tested, not opening it from the manager.

- Repro: `harness/t1/t1` in `S`.
- Root cause: `site(from:title:)` in `Sources/PasswordImport.swift`.

## Gaps the vault fix left

### 12. A planted enclave key with a fabricated vault

An attacker running as you can replace the gated key blob with a fresh enclave key and
write a whole new vault. It can't read your real secrets, because it never had K. But
your entries stop working, and any password you retype would be saved into the
attacker's vault. `load` catches a plain silent key. It shouldn't catch a key whose
access control demands presence from Rocket but also opens with an application
password. That second case is reasoned, not tested.

Fix direction: pin the gated key's public half in the keychain under a team-bound ACL.
That needs a Developer ID signature (issue 13).

### 13. Rocket is still signed ad-hoc

`/Applications/Rocket.app` reports `Signature=adhoc` and `TeamIdentifier=not set`. With
no team behind the signature, library validation is off, and a modified copy re-signed
ad-hoc still passes as Rocket and would receive your next Touch ID. That last part is
reasoned, not tested.

- There's no Developer ID Application certificate in the keychain:
  `security find-identity -v -p codesigning | grep "Developer ID Application"` prints
  nothing.
- Xcode's certificate menu offers only Apple Development, Apple Distribution and Mac
  Installer Distribution, which suggests this account isn't the team's Account Holder.
- Interim option: sign with the team's Apple Development certificate through
  `ROCKET_SIGN_ID`. That gives a real `TeamIdentifier` on this Mac only, with no
  notarisation. Untested.
- A guard that stops `./build.sh --install` and `--notarize` from falling back to
  ad-hoc is written but uncommitted, in worktree `P`.

### 14. Old-format vaults need the recovery key once

By design, a version 1 vault opens only through Restore from Recovery Key. Without the
key, the new build can't open it, though the file is left intact.

## Never tested

- **Your macOS password in a script's hands.** The local-attacker adversary was stopped
  by a safety classifier before running anything. Untested: whether the password can
  stand in for Touch ID, tampering with the app bundle, injecting code into Rocket, and
  who a Touch ID prompt appears to come from.
- **The AI agent server.** `AgentAccess`, `AgentToken`, `AgentPort` and
  `PasswordsLockAfter` live in plain `UserDefaults`, which any process running as you
  can read or write (read in source). Untested: whether a script can turn on agent
  access, read the token, and use `evaluate` to pull a password after a fill.
- **Passkeys.** The WebAuthn signing path and the passkey page script weren't attacked.
- **Native panel behaviour.** Clicks timed against the real panel, panels raised from
  background tabs, and clipboard clearing (which uses the real system clipboard).
- **Real Touch ID.** Every harness stubbed authentication. The vault fix ran on the real
  Secure Enclave, but with a silent key standing in for the gated one, and the app
  itself hasn't been launched with the new vault format.
