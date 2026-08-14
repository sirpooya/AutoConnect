# plan.md: MacAuth, TOTP authenticator + Cisco SAML VPN connector

Status: verified end to end on 2026-08-13 with `openconnect-sso`. This plan replaces that
Python tool with a native Swift menu-bar app.

---

## 1. What we proved

`openconnect-sso` connected successfully to the corporate gateway. Verified after connect:

- `utun6` -> `10.250.232.188`, default route via `utun6`
- Corporate DNS active (`172.30.6.21` / `172.30.6.22`); `works.digikala.com` resolved to `172.30.33.212`
- Session valid ~12 hours (`Session authentication will expire at Fri, 14 Aug 2026 10:30:25`)
- Cisco AnyConnect fully disconnected, openconnect owned the tunnel

Two install fixes were needed and are already applied: `setuptools<81` (for `pkg_resources`)
and removal of PyQt5 (the tool uses PyQt6). The `--server` value must carry an explicit
`https://` scheme or the host:port is misparsed as a URL scheme.

The trailing `is not a recognized network service` / `parameters were not valid` errors come
from `vpnc-script` iterating network services and hitting the Shadowrocket entry, which has an
empty device. Cosmetic. DNS is applied correctly regardless.

## 2. Why AnyConnect itself cannot be automated

The `MFA-VPN` tunnel group uses `single-sign-on-v2`, meaning SAML in an embedded webview.
Cisco renders that in its own WebKit window with macOS secure input on the password field,
which blocks synthetic keystrokes. Automator and AppleScript cannot type into it. The
AnyConnect CLI (`/opt/cisco/anyconnect/bin/vpn`) refuses outright:
`The requested authentication type is not supported in AnyConnect CLI`.

The openconnect CLI alone also fails (`No SSO handler`) because the gateway offers only
`single-sign-on-v2` and not `single-sign-on-external-browser`, and the CLI has no webview.

A webview we control has no secure-input restriction, which is what makes the Swift app work.

## 3. Gateway facts (discovered by probing, do not re-derive)

These are a record of what this gateway answered, not configuration. Nothing here is compiled
into the app: `VPNProfile.empty` is what a fresh install gets, Detect asks the gateway for its
groups, and the fingerprint is learned on first contact and pinned from then on. The table
stays so the values can be checked by eye, and so a live connect can be reasoned about without
probing again.

| Item | Value |
|---|---|
| Gateway | `https://mfa-vpn.dkservices.ir:28015` |
| Tunnel groups | `HQ-VPN` (AAA, double password), `MFA-VPN` (SAML) |
| MFA tunnel group name | `MFA-VPN_Profile` (alias `MFA-VPN`) |
| Auth method | `single-sign-on-v2` |
| SSO login URL | `https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml/sp/login?tgname=MFA-VPN_Profile&acsamlcap=v2` |
| SSO final URL | `https://mfa-vpn.dkservices.ir:28015/+CSCOE+/saml_ac_login.html` |
| Token cookie | `acSamlv2Token` |
| Error cookie | `acSamlv2Error` |
| IdP | `dsso.digikala.com` (ADFS) |
| Server cert SHA1 | `AA46A448019A03FFDAF8803558C9B19CE77B951B` (not signed by a trusted CA, must be pinned) |

`HQ-VPN` is scriptable with no browser at all, but is explicitly out of scope: the user
requires `MFA-VPN`.

## 4. The protocol to reimplement

Four steps. Steps 1, 3 and 4 are plain HTTP and process work. Only step 2 needs a webview.

1. **Init.** POST to the gateway root with `X-Aggregate-Auth: 1` and a `config-auth`
   body of `type="init"`, `<group-select>MFA-VPN</group-select>`. Response is
   `type="auth-request"` carrying `<sso-v2-login>`, `<sso-v2-login-final>`,
   `<sso-v2-token-cookie-name>` and the `<opaque>` block.
2. **Browser.** Load `sso-v2-login` in a `WKWebView`. When navigation reaches
   `sso-v2-login-final`, read the `acSamlv2Token` cookie from `WKHTTPCookieStore`.
   The `<opaque>` block must be echoed back verbatim in step 3.
3. **Auth reply.** POST `config-auth` of `type="auth-reply"` containing `<sso-token>` and
   the echoed `<opaque>`. Response contains `<session-token>` and
   `config/vpn-base-config/server-cert-hash`.
4. **Connect.** Spawn:
   ```
   openconnect --useragent "AnyConnect Linux_64 4.7.00136" --version-string 4.7.00136 \
     --cookie-on-stdin --servercert <server-cert-hash> \
     https://mfa-vpn.dkservices.ir:28015/
   ```
   and write the `session-token` to stdin. The AnyConnect user-agent spoof matters; some
   gateways reject unknown clients.

Note that the TOTP never reaches openconnect or the gateway. It only ever gets typed into the
IdP page. That is why the authenticator and the VPN connector belong in one app but stay
decoupled in code.

## 5. Constraints that change CLAUDE.md

| CLAUDE.md as written | Reality | Resolution |
|---|---|---|
| App Sandbox enabled | Sandbox blocks spawning `/opt/homebrew/bin/openconnect` and reading its output | **Sandbox off.** Document why. |
| "No network calls whatsoever" | The app must POST to the gateway and load the IdP page | **Network required.** Restrict to the gateway host and IdP by policy, not by entitlement. |
| Apple frameworks only | `openconnect` is an external binary | Still no Swift *packages*. The binary is a runtime dependency, detected at launch. |
| Clipboard copy is a headline feature | The VPN half consumes codes internally | Keep copy for the authenticator half; it stays useful for other services. |

Root privilege: `openconnect` must create a `utun` device. Two options, and the plan starts
with the first:

1. **sudoers NOPASSWD rule** for the openconnect binary. Five minutes, no code. Anyone who
   can run commands as the user can now bring up the VPN without a password prompt.
2. **Privileged helper** via `SMAppService` / `ServiceManagement`. Correct, survives
   distribution, needs a signed helper and an XPC interface. Defer to phase 8 if wanted.

## 6. Architecture

```
MacAuth/
├── MacAuthApp.swift              # @main, MenuBarExtra
├── Models/
│   ├── Account.swift             # issuer, label, secret ref, algorithm, digits, period
│   └── VPNProfile.swift          # gateway URL, tunnel group, cert pin, credential refs
├── Crypto/
│   ├── Base32.swift              # RFC 4648 decode
│   └── TOTP.swift                # RFC 6238
├── Storage/
│   └── KeychainStore.swift       # accounts, VPN password, TOTP seed
├── QR/
│   └── QRScanner.swift           # Vision otpauth:// extraction
├── VPN/
│   ├── GatewayClient.swift       # steps 1 and 3: config-auth XML over URLSession
│   ├── ConfigAuthXML.swift       # request builders + response parsing (pure, unit tested)
│   ├── SAMLLoginController.swift # step 2: WKWebView, autofill, cookie capture
│   ├── OpenConnectRunner.swift   # step 4: Process, stdout parsing, state machine
│   └── TunnelMonitor.swift       # utun presence, route check, expiry countdown
├── Views/
│   ├── MenuView.swift            # VPN status + countdown + account list
│   ├── LoginWindow.swift         # hosts the WKWebView, shown only when autofill stalls
│   ├── AddAccountView.swift
│   └── SettingsView.swift        # gateway, group, binary path, launch at login
└── Tests/
    ├── TOTPTests.swift           # RFC 6238 vectors, SHA1/256/512
    ├── Base32Tests.swift         # padding, lowercase, whitespace
    └── ConfigAuthXMLTests.swift  # parse captured real responses from fixtures
```

`ConfigAuthXML` and the crypto layer are pure and fully testable offline using captured
fixtures. Everything network- or process-touching sits behind a protocol so tests never
hit the gateway.

## 7. Phases

Two stages. **Stage A ships a complete, usable authenticator app** that can replace the Chrome
extension on its own. **Stage B** adds the VPN connector on top of it. Ordered this way on the
user's call, so there is a real working app in the menu bar before any VPN work starts.

> **Progress as of 2026-08-14.** Stage A is complete and in use. Stage B is written through B5 but
> **nothing has been run against the live gateway yet**: B1 is fixture-tested, B2 to B5 are
> unverified code. 103 tests pass. The user keeps their own `openconnect-sso` session running, so
> no connect, disconnect, or process kill happens without asking.

### Stage A: the authenticator app (ships standalone)

**A1. Crypto + tests.** `Base32.swift`, `TOTP.swift`, RFC 6238 vectors for SHA1/256/512.
Done when tests pass.

**A2. Account model.** `otpauth://` parsing with tests. Pure, no UI.

**A3. Keychain.** `KeychainStore` for accounts and their secrets.
`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`. Done when accounts survive relaunch.

**A4. Menu bar UI.** `MenuBarExtra` listing every account with issuer, label, live code, and a
per-account countdown ring. One-click copy with a "Copied" confirmation.

**A5. Account management.** Add by scanning a QR region of the screen (Vision), add by manual
entry, edit, and delete with confirmation.

**A6. Bundle + README.** A build script producing a signed `MacAuth.app` with `LSUIElement`.
Done when codes match the Chrome extension live, for both existing accounts.

### Stage B: the VPN connector

**B1. Gateway protocol, offline.** `ConfigAuthXML` builders and parsers against saved fixtures
of the real init and auth-reply responses. Done when tests parse the captured XML into typed values.

**B2. Manual SAML login.** `WKWebView` in a window, load the SSO URL, capture `acSamlv2Token`,
run steps 3 and 4, tunnel comes up. You still type everything by hand. Done when this connects
as reliably as `openconnect-sso` did.

**B3. Status UI.** Menu bar state for disconnected / connecting / connected, assigned IP, and a
countdown to session expiry parsed from openconnect stdout. Done when the menu shows what
AnyConnect used to show.

**B4. Autofill.** Inject username, password and TOTP into the IdP page via JavaScript, reading
from the Keychain and generating the code with the Stage A crypto. Keep a visible-window
fallback whenever a selector does not match. Done when a connect needs zero typing.

**B5. Reconnect and polish.** Auto-reconnect near expiry, reconnect on network change, launch at
login, disconnect that tears down cleanly.

**B6 (optional).** Replace the sudoers rule with an `SMAppService` privileged helper.

### What is written but unverified

Code exists and compiles for B2 to B5; none of it has met the gateway. The first live connect is
the next real milestone and needs the user present, because it disconnects their current session.

Two things that must be true before that run:

1. The sudoers rule is installed, scoped to the pid-file marker:
   ```
   pooya ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -INT -f /tmp/macauth-openconnect.pid
   ```
   An earlier version of this rule allowed `pkill -f openconnect`, which would have killed the
   user's own terminal session. Never widen it back.
2. A connection exists with an address, a group and a pin (all filled in by Detect), a username
   chosen from an authenticator account, and a password saved. Without those, autofill has
   nothing to work with and the login window simply waits for typing.

### Extras built beyond the original plan

- **Connections as a list.** Several can be configured, one is selected, and the menu bar acts
  on that one. Each carries its own gateway, credentials and OTP account, and its own Keychain
  item so deleting one cannot take another's password.
- **Gateway discovery.** A group-less init POST makes the gateway list its tunnel groups
  (`ConfigAuth.parseProbe`), and `GatewayClient.TrustPolicy.learnFingerprint` records the
  certificate on first contact. The only thing typed is the address.
- **Login-Keychain passwords.** A password a browser already saved can be reused instead of
  copied: listed by metadata (no prompt) in Settings, read at connect time (one prompt).

- **Statistics and a throughput chart.** openconnect has no stats option, so counters come from
  `netstat -ibn`. Sampling spawns a process, so it only runs while the statistics block is visible.
- **A tuning playground** (`Sources/MacAuth/Playground/`) that drives the real VPN row through all
  seven phases with fake data, so UI work needs no gateway.
- **`WindowActivation`**, a counted activation-policy switch. A menu-bar app must return to
  `.accessory` when its last window closes; left in `.regular`, `NSApp.activate` makes AppKit
  conjure a window, which surfaced as a blank Settings panel.

## 8. Risks

- **WKWebView persistence is the whole payoff.** If the ADFS `MSISAuth` cookie survives in
  `WKWebsiteDataStore.default()`, most reconnects skip the IdP entirely and no OTP is needed.
  If ADFS forces re-auth every time, autofill still removes the typing. Either way the app wins,
  but the size of the win is unknown until phase 4 is running.
- **IdP page changes.** Autofill selectors are tied to Digikala's login markup. Any redesign
  breaks it. Mitigation: never fail closed, always fall back to showing the window.
- **Cert pinning.** The gateway cert has no trusted signer, so `WKWebView` will also object.
  Pin the known SHA1 and refuse anything else rather than disabling validation wholesale.
- **Re-signing invalidates Keychain ACLs.** Changing signing identity can lock the app out of
  its own items. Keep one identity, or handle the re-prompt gracefully.
- **Homebrew dependency.** The app is not self-contained. Detect the binary at launch and
  tell the user to `brew install openconnect` rather than failing obscurely.
- **Security tradeoff, stated plainly.** Storing the corporate password and the TOTP seed on
  one machine means that machine alone can complete both factors. That is a real reduction in
  what MFA buys, it may conflict with company policy, and it is the user's call to make.

## 9. Open questions

1. ~~Do you have the raw Base32 TOTP seed?~~ **Answered:** yes, available as a QR code, which
   encodes the `otpauth://` URI including the Base32 secret. The app's own QR scanner reads it,
   so nothing is hardcoded.
2. ~~Is there actually an OTP step?~~ **Answered:** yes. The login is username, then password,
   then OTP. Three fields, all inside the webview. An earlier guess from log timestamps that
   there might be no OTP step was wrong. Autofill injects three fields instead of two, which
   changes nothing structurally.
3. **Exact IdP field selectors.** Needed for phase 6. Captured from the live page once phase 4
   runs.
4. **sudoers rule or privileged helper** for the first working version.

Also settled: the authenticator half is a real authenticator, not a single hardcoded account.
Multiple accounts (currently two: `p.kamel@` and `design@`, both issuer `DigikalaMFA`), scan by
QR, add manually, edit, delete, and a per-account countdown. The VPN half simply points at
whichever stored account is its OTP source.

## 10. Environment

Verified on this machine: macOS 26.5.1, Xcode 26.6, Swift 6.3.3, arm64.
`openconnect` 9.21 at `/opt/homebrew/bin/openconnect`, vpnc-script at
`/opt/homebrew/etc/vpnc/vpnc-script`. Signing identity available:
`Apple Development: pooyak@live.com`.

CLAUDE.md sets a minimum target of macOS 14. Nothing in this plan needs anything newer, so
that target stands.
