# AutoConnect

A native macOS menu-bar app that replaces Cisco AnyConnect, built with Apple frameworks only.

It is two halves sharing a Keychain and a crypto layer. The connector drives the SAML login in a
`WKWebView` it owns, captures the session token, and hands it to `openconnect`, showing live
status, the assigned IP, and a countdown to expiry. The authenticator is a full RFC 6238 TOTP
client, and it feeds its own code into that login: the name is the point, a connect takes no
typing.

Secrets live in the Keychain. There is no account, no sync, and no telemetry of any kind. See
[plan.md](plan.md) for the gateway protocol and for why AnyConnect itself cannot be automated.

## Build and run

```bash
swift test              # 176 tests, including every RFC 6238 Appendix B vector
./Scripts/make-app.sh   # produces build/AutoConnect.app, signed
open build/AutoConnect.app
```

For a build with the tuning playground and its footer button:

```bash
CONFIG=debug ./Scripts/make-app.sh
```

To keep it around:

```bash
cp -R build/AutoConnect.app /Applications/
```

To quit:

```bash
osascript -e 'quit app "AutoConnect"'
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
  AutoConnectCore/              # pure logic, no UI, all of it unit tested
    Crypto/                 # Base32 (RFC 4648), TOTP (RFC 6238 + 4226)
    Models/                 # Account + otpauth:// parsing, VPNProfile
    Storage/                # AccountStoring, KeychainStore, VPNSettingsStore,
                            # LoginKeychain, LegacyMigration
    VPN/                    # ConfigAuthXML, GatewayClient, OpenConnectRunner,
                            # ReconnectPolicy, StatusNotification, TunnelStats
  AutoConnect/                  # the app
    StatusItemController.swift   # NSStatusItem + NSPopover
    AppState.swift               # accounts, ticker, code cache, clipboard
    WindowActivation.swift       # counted activation-policy switching
    QR/                          # Vision barcode detection
    VPN/                         # VPNController, SAMLLoginController, LoginFormFiller
    Notifications/               # VPNStatusNotifier, the delivery half of the banners
    Views/                       # panel, VPN section, chart, rows, forms, settings
    Playground/                  # dev-only tuning window
Tests/AutoConnectCoreTests/     # 176 tests
```

A Swift package rather than an Xcode project, so `swift test` runs the whole suite from the
terminal, and `Scripts/make-app.sh` wraps the executable into the `.app` bundle a menu-bar app
needs. Two deviations from the layout sketched in CLAUDE.md, both deliberate and documented there:
the split into a core library plus an app target, and `NSStatusItem` in place of `MenuBarExtra`
(which gives no control over where its window lands).

## How secrets are stored

One Keychain generic-password item per account:

| Field | Contents |
|---|---|
| `kSecAttrService` | `com.pooya.AutoConnect.accounts` |
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

### Carried over from the old name

The app used to be called MacAuth, and three identifiers had that name inside them: the two
Keychain services, the bundle identifier `com.pooya.MacAuth` (which is what decides the
preferences domain `UserDefaults.standard` reads), and the `macauth.` prefix on every defaults
key. All three decide where data lives, so renaming them alone would have left a working app
pointed at empty storage, with the accounts looking deleted.

`LegacyMigration` handles it on first launch, once: it re-tags each Keychain item's
`kSecAttrService` in place, keeping the secret and its access control intact, and copies every
`macauth.`-prefixed default out of the old preferences domain under the new prefix. A value
already set since the rename is left alone. On a Mac that never ran the old app it does nothing.

Two things it cannot do anything about, both one-time and both harmless:

- macOS asks once more for Keychain access, because the item's access control names the app that
  created it and the bundle identifier is part of that name. Choose "Always Allow".
- A login item registered under the old bundle identifier stays behind as a stale entry in System
  Settings, Login Items. Toggle "Launch at login" off and on to replace it.

The migration can be deleted once no machine is still carrying MacAuth-era data.

## The VPN half

Settings (Cmd+comma, or the footer button) configures everything; nothing is hardcoded:

| Setting | Purpose |
|---|---|
| Address, Group | The gateway and its tunnel group, as AnyConnect's dropdown shows them |
| Certificate SHA1 | Pins the gateway, which typically has no publicly trusted signer |
| Username | Typed into the identity provider's form |
| Password | Stored in the Keychain, never in a plist |
| OTP from | Which authenticator account supplies the one-time code |
| Reconnect automatically | Renews before expiry, restores after a drop or network change |
| Notify on VPN status changes | Banners for connect, disconnect, and trouble. Off until switched on |
| Launch at login | Registers a login item via `SMAppService` |
| Binary | Path to openconnect, with a warning when it is missing |

Connecting runs four steps: ask the gateway how to authenticate, log in through a `WKWebView` this
app owns, trade the resulting SAML token for a session token, then hand that to `openconnect` over
stdin. The full protocol is documented in [plan.md](plan.md) section 4.

While connected the panel shows the gateway, the assigned address, a countdown to session expiry,
and behind a disclosure a throughput chart plus traffic, transferred, uptime, transport, interface
and MTU. Counters come from `netstat`, sampled only while that block is open.

With automatic reconnect on, that countdown is not meant to reach zero. `ReconnectPolicy` renews
five minutes before the gateway's hard expiry, which takes the tunnel down and brings it back with
a fresh session, so the countdown jumps back to a full session rather than running out. A minute or
less on the clock therefore means the renewal did not take: failures back off 30s, 60s, 120s and so
on up to ten minutes, and after three in a row automatic retries stop and the panel says so. With
automatic reconnect off, the session simply expires and openconnect exits.

### Status notifications

Off until switched on in Settings, General. Flipping the switch is what asks macOS for
permission, and the three kinds below it (connected, disconnected, reconnecting or failed) can be
turned off separately. Banners are silent, and each one replaces the last rather than stacking.

Only changes in whether the machine is on the VPN are announced: the steps of a connect are not,
the same state twice running says so once, and an automatic renewal, which takes the tunnel down
in order to bring it back, stays quiet unless it fails. A test notification button is there
because the alternative way to check permission is to connect the VPN and hope.

Notifications need the packaged `build/AutoConnect.app`. Under `swift run` there is no bundle
identifier, `UNUserNotificationCenter` would trap, and the app says so instead.

### Two safety properties worth knowing

**Shutdown cannot touch another openconnect.** The tunnel is started with
`--pid-file /tmp/autoconnect-openconnect.pid` and stopped by matching that path, so an openconnect you
started yourself in a terminal is never a target. A test asserts the kill pattern contains no bare
process-name match.

**Autofill never fails closed.** The injected script reports what the page is asking for and the
app answers with one value; the password is only ever sent to an HTTPS origin reached by following
redirects from the gateway's own login URL. When a field cannot be found, or the page reports an
error, autofill stops and the window stays open for you to finish by hand.

### Root privilege

openconnect needs root to create the tunnel device. Either accept a password prompt per connect, or
install a narrowly scoped sudoers rule:

```
pooya ALL=(root) NOPASSWD: /opt/homebrew/bin/openconnect, /usr/bin/pkill -INT -f /tmp/autoconnect-openconnect.pid
```

Be aware of what that buys: openconnect can run arbitrary scripts via `--script`, so the rule is
effectively passwordless root for anything running as you. Replacing it with a privileged helper is
the remaining optional phase.

## Verifying correctness

The test suite covers all 18 RFC 6238 Appendix B vectors across SHA1, SHA256 and SHA512, the ten
RFC 4226 counter vectors, the RFC 4648 Base32 vectors, and the awkward real-world Base32 cases
(lowercase, missing padding, spaces, hyphens, impossible lengths). The Keychain tests run against
the real macOS Keychain using a throwaway service name.

The final check is human: add your real account and confirm the code matches whatever
authenticator you use today, in the same second.
