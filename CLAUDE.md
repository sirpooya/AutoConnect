# CLAUDE.md: MacAuth (macOS menu-bar TOTP authenticator + Cisco SAML VPN connector)

## Goal
A native macOS menu-bar app in Swift with two halves that share a Keychain and a crypto layer.

**Primary half: VPN connector.** Replace Cisco AnyConnect for the `MFA-VPN` SAML tunnel group.
Log in through a `WKWebView` we control, capture the `acSamlv2Token` cookie, exchange it for a
session token, and hand that to `openconnect`. Show live status, assigned IP, and a countdown to
session expiry. Auto-reconnect.

**Secondary half: authenticator.** Scan `otpauth://` QR codes, store secrets in the Keychain,
generate live RFC 6238 codes with a countdown, and copy to clipboard in one click. The VPN half
consumes codes internally rather than via the clipboard.

**Read `plan.md` before writing any code.** It records the gateway protocol, the discovered
gateway facts, the phase order, and the open questions. Do not re-derive them.

Keep it minimal and dependency-light. No cloud sync, no accounts, no analytics.

## Tech Stack (Apple frameworks only, no Swift packages)
- **Language:** Swift 5.9+
- **UI:** SwiftUI + `MenuBarExtra` (menu bar app)
- **Min target:** macOS 14 (Sonoma)
- **QR decode:** `Vision` (`VNDetectBarcodesRequest`) for screen-capture images; `AVFoundation` if using the camera
- **Crypto / TOTP:** `CryptoKit` (`HMAC<Insecure.SHA1>`, plus SHA256/SHA512 support)
- **Storage:** macOS **Keychain** via the Security framework (never plist/UserDefaults for secrets)
- **Clipboard:** `NSPasteboard`
- **Base32:** implement a small RFC 4648 Base32 decoder (secrets in `otpauth://` are Base32; Foundation only has Base64)
- **SAML login:** `WebKit` (`WKWebView`, `WKHTTPCookieStore`, `WKWebsiteDataStore`)
- **Gateway calls:** `URLSession` posting Cisco `config-auth` XML
- **Tunnel:** `Process` spawning `/opt/homebrew/bin/openconnect` (runtime dependency, detected at launch)

> Do NOT add SwiftOTP, or any Swift package, unless a task truly needs it. Ask first.
> `openconnect` is an external binary, not a library dependency; that is the one exception.

## Project Layout
```
MacAuth/
├── MacAuthApp.swift              # @main, MenuBarExtra scene
├── Models/
│   ├── Account.swift             # issuer, label, secret ref, algorithm, digits, period
│   └── VPNProfile.swift          # gateway URL, tunnel group, cert pin, credential refs
├── Crypto/
│   ├── Base32.swift              # RFC 4648 decode
│   └── TOTP.swift                # RFC 6238 code generation
├── Storage/
│   └── KeychainStore.swift       # accounts, VPN password, TOTP seed
├── QR/
│   └── QRScanner.swift           # Vision-based otpauth:// extraction
├── VPN/
│   ├── GatewayClient.swift       # config-auth init + auth-reply over URLSession
│   ├── ConfigAuthXML.swift       # request builders + response parsing (pure, unit tested)
│   ├── SAMLLoginController.swift # WKWebView login, autofill, acSamlv2Token capture
│   ├── OpenConnectRunner.swift   # Process spawn, stdout parsing, state machine
│   └── TunnelMonitor.swift       # utun presence, route check, expiry countdown
├── Views/
│   ├── MenuView.swift            # VPN status + countdown + account list
│   ├── LoginWindow.swift         # hosts the WKWebView, shown only when autofill stalls
│   ├── AddAccountView.swift      # add via QR or manual secret entry
│   └── SettingsView.swift        # gateway, group, binary path, launch at login
└── Tests/
    ├── TOTPTests.swift           # RFC 6238 test vectors
    ├── Base32Tests.swift         # padding, lowercase, whitespace
    └── ConfigAuthXMLTests.swift  # parse captured real gateway responses from fixtures
```

## TOTP Spec (must match RFC 6238 exactly)
- Default: **SHA1, 6 digits, 30-second period** (Google Authenticator defaults).
- Also parse and honor `algorithm`, `digits`, and `period` from the `otpauth://` URI.
- Algorithm:
  1. `counter = floor(currentUnixTime / period)` as an 8-byte big-endian value.
  2. `hmac = HMAC(key = base32Decode(secret), message = counter)`.
  3. Dynamic truncation: `offset = hmac[last byte] & 0x0f`; take 4 bytes at offset, mask top bit (`& 0x7fffffff`).
  4. `code = truncated % 10^digits`, zero-padded to `digits`.
- **Verify against RFC 6238 Appendix B test vectors** in unit tests before wiring UI. (Secret `12345678901234567890`, T=59 → `94287082` for SHA1/8-digit, etc.)

## `otpauth://` URI Format
```
otpauth://totp/Issuer:account@example.com?secret=BASE32SECRET&issuer=Issuer&algorithm=SHA1&digits=6&period=30
```
Parse with `URLComponents`. `secret` is required. Strip padding/whitespace before Base32 decode.

## VPN Connector Spec
The full four-step protocol, the discovered gateway values, and the cert pin live in `plan.md`
section 4 and section 3. Summary of the behavior contract:

- Menu bar icon reflects state: disconnected, connecting, connected, reconnecting, error.
- Connected state shows the assigned tunnel IP and a live countdown to session expiry, parsed
  from openconnect's `Session authentication will expire at ...` line.
- Connect flow: gateway init, `WKWebView` SAML login, auth-reply, spawn openconnect with
  `--cookie-on-stdin --servercert <pin>` and write the session token to stdin.
- Autofill injects email, password and TOTP into the IdP page from the Keychain.
  **Never fail closed:** if any selector does not match, show the login window and let the user
  finish by hand.
- Pin the gateway cert by SHA1. Do not disable TLS validation wholesale.
- Detect the openconnect binary at launch; if missing, say so plainly and point at
  `brew install openconnect`.
- Disconnect must actually tear down the tunnel and restore routing.

## Features / Behavior (authenticator half)
- Menu bar dropdown lists each account with issuer, label, live code, and a shrinking progress ring/bar for the period.
- Click a code (or a copy button) runs `NSPasteboard.general.clearContents()` then `setString(code, forType: .string)`; show a brief "Copied" confirmation.
- **Add account:**
  - *QR:* let user capture a region of the screen (or drop an image); decode with Vision; parse `otpauth://`.
  - *Manual:* text fields for issuer, account, and Base32 secret.
- Codes refresh every second; recompute on each period boundary.
- Delete account with confirmation, which also removes it from the Keychain.

## Security Requirements
- Secrets live ONLY in the Keychain (`kSecClassGenericPassword`, `kSecAttrAccessibleWhenUnlocked`). Never log them or write them to disk in plaintext.
- Never log the TOTP seed, the VPN password, the `acSamlv2Token`, or the session token. Redact
  tokens in any diagnostic output.
- Keep secrets out of SwiftUI state longer than needed; hold decoded key data only during code generation.
- **The App Sandbox must be OFF, and network access is required.** This reverses the original
  spec, for two unavoidable reasons: a sandboxed app cannot spawn `/opt/homebrew/bin/openconnect`
  or read its output, and the connector must reach the gateway and the IdP. Restrict traffic to
  the gateway host and the IdP by code, since the entitlement can no longer do it.
- Root privilege for the `utun` device: start with a sudoers NOPASSWD rule for the openconnect
  binary, and treat an `SMAppService` privileged helper as a later phase. Document the tradeoff
  in the README, including that the rule lets anything running as this user start the VPN.
- Storing the corporate password and TOTP seed together on one machine means that machine alone
  satisfies both factors. This is a deliberate, user-approved tradeoff. Note it in the README;
  do not silently expand it (no exporting secrets, no syncing, no telemetry).

## Build / Run
- Prefer a Swift Package (`swift build` / `swift run`) or a minimal Xcode project. Pick one and document it in README.
- Provide a README with build steps and how to sign for local run.
- If camera QR is used, add `NSCameraUsageDescription` to Info.plist.
- Keep one signing identity. Re-signing with a different identity can lock the app out of its
  own Keychain items.
- Verified toolchain on this machine: macOS 26.5.1, Xcode 26.6, Swift 6.3.3, arm64.

## Definition of Done

VPN connector (primary):
- [ ] `ConfigAuthXML` parses captured real init and auth-reply responses in unit tests.
- [ ] Connects to `MFA-VPN` end to end and brings up a working tunnel with corporate DNS.
- [ ] Menu bar shows state, assigned IP, and a live countdown to session expiry.
- [ ] Autofill completes a connect with zero typing, and falls back to a visible window when a
      selector fails.
- [ ] Cert pinned by SHA1; a mismatched cert refuses to connect.
- [ ] Disconnect tears down the tunnel and restores routing.
- [ ] Auto-reconnect near expiry works.
- [ ] Missing openconnect binary produces a clear, actionable message.

Authenticator (secondary):
- [ ] TOTP unit tests pass against RFC 6238 vectors (SHA1/256/512).
- [ ] Base32 decoder handles padding and lowercase input.
- [ ] Can add an account via `otpauth://` QR and via manual entry.
- [ ] Live code + countdown render in the menu bar dropdown.
- [ ] One-click copy to clipboard works with visual confirmation.
- [ ] Secrets persist across launches via Keychain; delete removes them.

## Working Style for Claude Code
- **Read `plan.md` first.** Follow its phase order. It exists so the gateway protocol and the
  discovered facts are not rediscovered every session.
- Start with `Base32.swift` and `TOTP.swift` + tests; get codes matching a real authenticator
  before touching UI.
- Then `KeychainStore`, then the gateway XML layer against fixtures, then the manual `WKWebView`
  login, then status UI, then autofill. QR scanning last.
- Get a manual path working before automating it. Autofill is the most fragile part and should
  never be the only path.
- Capture real gateway and IdP responses as test fixtures, with secrets redacted.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.
