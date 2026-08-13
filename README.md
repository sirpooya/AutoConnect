# MacAuth

A native macOS menu-bar TOTP authenticator, built with Apple frameworks only. Secrets live in
the Keychain, nothing touches the network, and there is no account or sync of any kind.

Stage two of this project adds a Cisco SAML VPN connector on top of the same crypto and Keychain
layer. See [plan.md](plan.md) for that design and for why Cisco AnyConnect cannot be automated
directly.

## Build and run

```bash
swift test              # 44 tests, including every RFC 6238 Appendix B vector
./Scripts/make-app.sh   # produces build/MacAuth.app, signed
open build/MacAuth.app
```

To keep it around:

```bash
cp -R build/MacAuth.app /Applications/
```

To quit:

```bash
osascript -e 'quit app "MacAuth"'
```

The app is menu-bar only (`LSUIElement`), so it has no Dock icon and no main window. Look for the
lock icon in the menu bar.

### Signing

`make-app.sh` signs with the first `Apple Development` identity it finds, falling back to an
ad-hoc signature. Keep the identity stable: re-signing with a different one makes macOS re-prompt
for Keychain access, since the item ACLs are tied to the code signature.

Override it explicitly if needed:

```bash
SIGN_IDENTITY="-" ./Scripts/make-app.sh          # ad-hoc
SIGN_IDENTITY="Developer ID Application: ..." ./Scripts/make-app.sh
```

## Using it

**Add an account** from the `+` menu:

- *Scan Region of Screen* drags a selection box over an on-screen QR code. This shells out to
  `/usr/sbin/screencapture -i`, which the system draws itself, so the app never needs Screen
  Recording permission.
- *Open QR Image* picks a saved screenshot or enrollment image.
- *Paste otpauth:// Link* reads a URI from the clipboard.
- *Enter Secret Manually* takes an issuer, account name and Base32 secret.

You can also drag a QR image file straight onto the panel.

**Copy a code** by clicking anywhere on its row. The digits turn green and the ring shows
"Copied" for a moment.

**Edit or delete** with a right-click on any row. Deleting asks for confirmation and removes the
secret from the Keychain permanently.

Each row shows a countdown ring that turns amber in the last third of the period and red in the
final five seconds. Accounts using non-default settings (anything other than SHA1 / 6 digits /
30 seconds) show those settings next to the issuer, so a mismatched code is easy to diagnose.

## Layout

```
Sources/
  MacAuthCore/            # pure logic, no UI, fully unit tested
    Crypto/Base32.swift   # RFC 4648
    Crypto/TOTP.swift     # RFC 6238 + RFC 4226 truncation
    Models/Account.swift  # account model + otpauth:// parsing
    Storage/KeychainStore.swift
  MacAuth/                # the menu bar app
    MacAuthApp.swift      # MenuBarExtra scene
    AppState.swift        # accounts, ticker, code cache, clipboard
    QR/QRScanner.swift    # Vision barcode detection
    Views/                # panel, rows, form, confirmations
Tests/MacAuthCoreTests/   # 44 tests
```

This is a Swift package rather than an Xcode project, so `swift test` runs the whole core suite
from the terminal. `Scripts/make-app.sh` wraps the executable into the `.app` bundle that a
menu-bar app needs. That is the one deviation from the layout in CLAUDE.md, which assumed a
single flat target.

## How secrets are stored

One Keychain generic-password item per account:

| Field | Contents |
|---|---|
| `kSecAttrService` | `com.pooya.MacAuth.accounts` |
| `kSecAttrAccount` | the account's UUID |
| `kSecAttrComment` | JSON metadata: issuer, label, algorithm, digits, period, sort index |
| `kSecValueData` | the raw TOTP secret |
| `kSecAttrAccessible` | `kSecAttrAccessibleWhenUnlocked` |

Metadata sits in an attribute rather than in the payload for a specific reason: listing accounts
requests attributes only, so secrets are never loaded just to draw the menu. A secret is read
only at the moment a code is generated, and generated codes are cached for the remaining
lifetime of their 30-second step, so the Keychain is touched roughly once per account per period
instead of once per second.

Nothing is written to `UserDefaults` or to any plist. Secrets are never logged.

## Verifying correctness

The test suite covers all 18 RFC 6238 Appendix B vectors across SHA1, SHA256 and SHA512, the ten
RFC 4226 counter vectors, the RFC 4648 Base32 vectors, and the awkward real-world Base32 cases
(lowercase, missing padding, spaces, hyphens, impossible lengths). The Keychain tests run against
the real macOS Keychain using a throwaway service name.

The final check is human: add your real account and confirm the code matches whatever
authenticator you use today, in the same second.
