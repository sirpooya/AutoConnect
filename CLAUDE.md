# CLAUDE.md: AutoConnect (macOS menu-bar Cisco SAML VPN connector + TOTP authenticator)

## Goal
A native macOS menu-bar app in Swift with two halves that share a Keychain and a crypto layer.

**Primary half: VPN connector.** Replace Cisco AnyConnect for a Cisco SAML tunnel group.
No gateway, group, fingerprint or username is compiled in: the user types an address and the
app asks that gateway for the rest.
Log in through a `WKWebView` we control, capture the `acSamlv2Token` cookie, exchange it for a
session token, and hand that to `openconnect`. Show live status, assigned IP, and a countdown to
session expiry. Auto-reconnect.

**Secondary half: authenticator.** Scan `otpauth://` QR codes, store secrets in the Keychain,
generate live RFC 6238 codes with a countdown, and copy to clipboard in one click. The VPN half
consumes codes internally rather than via the clipboard.

**Read `plan.md` before writing any code.** It records the gateway protocol, the discovered
gateway facts, the phase order, and the open questions. Do not re-derive them.

Keep it minimal and dependency-light. No cloud sync, no accounts, no analytics.

## Tech Stack (Apple frameworks, plus Sparkle for updates)
- **Language:** Swift 5.9+
- **UI:** SwiftUI views hosted by AppKit: `NSStatusItem` + `NSPopover`, not `MenuBarExtra`
- **Min target:** macOS 14 (Sonoma)
- **QR decode:** `Vision` (`VNDetectBarcodesRequest`) for screen-capture images; `AVFoundation` if using the camera
- **Crypto / TOTP:** `CryptoKit` (`HMAC<Insecure.SHA1>`, plus SHA256/SHA512 support)
- **Storage:** macOS **Keychain** via the Security framework (never plist/UserDefaults for secrets)
- **Clipboard:** `NSPasteboard`
- **Base32:** implement a small RFC 4648 Base32 decoder (secrets in `otpauth://` are Base32; Foundation only has Base64)
- **SAML login:** `WebKit` (`WKWebView`, `WKHTTPCookieStore`, `WKWebsiteDataStore`)
- **Gateway calls:** `URLSession` posting Cisco `config-auth` XML
- **Tunnel:** `Process` spawning `/opt/homebrew/bin/openconnect` (runtime dependency, detected at launch)
- **Updates:** `Sparkle` 2.9+, the one Swift package, wrapped by `UpdateController`

> Do NOT add SwiftOTP, or any other Swift package, unless a task truly needs it. Ask first.
> There are two approved exceptions. `openconnect` is an external binary, not a library
> dependency. Sparkle is a real package dependency, added deliberately: the app is distributed as
> a zip on a GitHub release, so without in-app updates the only way anyone learns a new version
> exists is by going back to the releases page, and the only way they install it is by replacing
> the bundle by hand.

## Project Layout

A Swift package with two targets, so `swift test` covers all the logic from the terminal and the
UI stays out of the tested surface. `Scripts/make-app.sh` wraps the executable into the `.app`
bundle a menu-bar app needs. **Anything worth testing belongs in `AutoConnectCore`**, which is why
`ReconnectPolicy` lives there despite being used only by the app.

```
Sources/
├── AutoConnectCore/                      # pure logic, no UI, 235 tests
│   ├── Crypto/
│   │   ├── Base32.swift              # RFC 4648 decode + encode
│   │   └── TOTP.swift                # RFC 6238 / RFC 4226 truncation
│   ├── Models/
│   │   ├── Account.swift             # metadata + otpauth:// parsing (never holds a secret)
│   │   ├── Credential.swift          # legacy: decoded only to fold back into a connection
│   │   └── VPNProfile.swift          # one connection: gateway, group, pin, username, OTP
│   ├── Storage/
│   │   ├── AccountStoring.swift      # storage protocol + InMemoryAccountStore for fakes
│   │   ├── KeychainStore.swift       # accounts and their TOTP secrets
│   │   ├── LegacyMigration.swift     # carries MacAuth-era Keychain items and defaults across
│   │   ├── LoginKeychain.swift       # website passwords a browser already saved
│   │   └── VPNSettingsStore.swift    # connection list + selection, VPN password in Keychain
│   └── VPN/
│       ├── ConfigAuthXML.swift        # Cisco config-auth builders, parser, group probe
│       ├── GatewayClient.swift        # the POSTs, SHA1 pinning, learn-on-first-contact
│       ├── OpenConnectRunner.swift    # process spawn, output parsing, state machine
│       ├── OpenConnectVersion.swift   # asks the installed binary what version it is
│       ├── PinnedCertificate.swift    # what the pinned cert says: names, issuer, expiry
│       ├── ReconnectPolicy.swift      # when to renew, back off, give up, or distrust "connected"
│       ├── SetupCommands.swift        # install and sudo lines the user copies, built from the same constants
│       ├── StatusNotification.swift   # which status changes earn a banner, and what it says
│       └── TunnelStats.swift          # netstat counters, rates, byte formatting
└── AutoConnect/                           # the app
    ├── AutoConnectApp.swift           # @main, and a never-inserted scene so it has one
    ├── SettingsWindow.swift           # AppKit-hosted settings, not a Settings scene
    ├── StatusItemController.swift     # NSStatusItem + NSPopover (not MenuBarExtra, see below)
    ├── AppState.swift                 # accounts, ticker, code cache, clipboard
    ├── PanelPin.swift                 # keeps the popover up across system windows
    ├── WindowActivation.swift         # counted .regular/.accessory policy switching
    ├── LaunchAtLogin.swift            # SMAppService login item
    ├── QR/QRScanner.swift             # Vision barcode detection
    ├── Notifications/
    │   └── VPNStatusNotifier.swift    # permission and delivery for the status banners
    ├── Updates/
    │   └── UpdateController.swift     # Sparkle: the tunnel gate and the activation policy
    ├── VPN/
    │   ├── VPNController.swift        # sequences the four connect steps, owns VPN state
    │   ├── SAMLLoginController.swift  # WKWebView login, acSamlv2Token capture
    │   └── LoginFormFiller.swift      # injected scanner/filler for the IdP form
    ├── Views/
    │   ├── MenuPanel.swift            # panel root, account list, add menu
    │   ├── VPNSection.swift           # status, connection switcher, statistics
    │   ├── StatusLine.swift           # the status text, its shimmer, and StatusPacer
    │   ├── ThroughputChart.swift      # download area + upload line sparkline
    │   ├── AccountRow.swift           # code, countdown pie, copy
    │   ├── AccountDetailsView.swift   # what an account is, with nothing to change
    │   ├── SettingsComponents.swift   # cards, rows, dividers, WidePopUpButton
    │   ├── SettingsView.swift         # General / Connections / Authenticator / About tabs
    │   ├── AboutTab.swift             # version, updates, source
    │   ├── ConnectionEditorView.swift # one connection: address, Detect, credentials
    │   └── SystemCertificateIcon.swift # Keychain Access artwork, loaded from the system
    └── Playground/
        ├── PlaygroundWindow.swift     # app-owned NSWindow for it, not a SwiftUI scene
        └── VPNStatusPlayground.swift  # dev-only tuning window, fake VPN states
```

Settings is an `NSWindow` this app owns (`SettingsWindow`), not a SwiftUI `Settings` scene:
as the only presentable scene, macOS opened that by itself at launch. Size the window
explicitly rather than from `preferredContentSize`, or AppKit re-measures the SwiftUI content
mid-layout and the app dies with "more Update Constraints in Window passes than there are
views in the window". `show(tab:)` chooses where a freshly opened pane starts, which is how the
panel's Set Up button lands on Connections; a window already on screen keeps the tab the user
left it on rather than jumping under them.

`MenuBarExtra` was replaced by `NSStatusItem` + `NSPopover`: `MenuBarExtra` gives no control over
where its window lands, while a popover anchored to the status button is always centred on the
icon. Keep it that way.

Two rules come with that popover, both learned from bugs:

- **AppKit installs the monitors that dismiss a `.transient` popover at show time.** `PanelPin`
  flips the behaviour to `.applicationDefined` so the file picker, the capture overlay and the
  sign-in window cannot dismiss the panel mid-add. Flipping it back is not enough: the popover
  must be closed and shown again, or it ignores clicks elsewhere for the rest of its life.
- The panel also closes on `NSApplication.didResignActiveNotification`, gated on the pin. The
  popover's own monitors miss cases such as focus leaving while a menu inside it is open, and a
  menu bar panel left open in the background is the one thing it must never do.

## Menu bar and app icons
Both are vector artwork the user supplies; neither is drawn in code.

- Status item: `Sources/AutoConnect/Resources/on.pdf` and `off.pdf`, shipped as SwiftPM resources and
  loaded by `MenuBarIcon` at 18x18pt with `isTemplate = true` so macOS tints them for light, dark
  and the inverted open state. The SVG next to each PDF is the editable source and is excluded
  from the build. `StatusItemController.apply(phase:)` swaps them: **only `.connected` gets the on
  glyph**, so the icon never implies a tunnel that is connecting, reconnecting or failed.
- App icon: `Icons/AppIcon.icon`, an Icon Composer document. `make-app.sh` compiles it with
  `actool` into both `Assets.car`, which macOS 26 reads for the layered Liquid Glass icon, and a
  plain `AppIcon.icns` for anything older, then writes `CFBundleIconFile` and `CFBundleIconName`.
- **Pass `actool` absolute paths.** It resolves relative ones against its own working directory,
  not the shell's, and fails claiming the output directory does not exist.
- `make-app.sh` also copies SwiftPM's `AutoConnect_AutoConnect.bundle` into `Contents/Resources`, which is
  what makes `Bundle.module` resolve inside the packaged app rather than only under `swift run`.
- **Several glyph sets exist**, chosen with the playground's Menu bar picker: keyhole arc (the
  default), keyhole in circle, padlock, globe, lock. Every set is a pair, outline for disconnected
  and filled for connected, so the meaning survives whichever is picked. Sets that read state only
  through a small added badge, rather than through the fill, were tried and dropped: at 18pt the two
  states looked identical.
- `MenuBarIconSet` has **explicit raw values with gaps**. The choice is persisted, so renumbering
  the survivors after deleting a set would silently move a saved selection onto a different glyph.
  `VPNStatusParams.init` also snaps an index that matches no case back to the default, or the
  picker holds a selection it cannot display.
- **Removing a resource needs the SwiftPM bundle cleared.** Deleted files stay in
  `.build/*/AutoConnect_AutoConnect.bundle`, and `make-app.sh` copies that bundle wholesale, so the
  app keeps shipping artwork that is no longer in the repo. `rm -rf` the bundle and rebuild.

## Panel UI conventions
The panel is roughly 320pt wide, so restraint is the whole design. Established by review, and
worth keeping unless the user says otherwise:

- **11pt is the base text size**, and nearly everything is 11pt: the VPN title, its status line,
  the account heading, the footer buttons. Weight and `.secondary` / `.tertiary` carry hierarchy,
  not size. Sizes drifting to 7, 8, 9 and 10pt in one block is what made it look assembled from
  spare parts. The code itself is the one deliberate exception at 19pt.
- **Nothing appears, disappears or resizes on hover.** No "Copy" label, no "Copied" label: they
  changed the row height. The row highlight is the hover affordance, and the code turning green
  is the copy confirmation.
- **The countdown is a neutral filled wedge with no digits**, at every stage. No accent colour, no
  amber, no red: the shape already says how much time is left.
- The status dot is a plain filled circle. No halo, no pulse.
- **The phase is paced, not the status string.** `StatusPacer` holds each phase on screen for a
  minimum dwell, so a gateway that answers in milliseconds cannot flash a status past unread. The
  dot, the connected block and the error row all read the paced phase, or a connect that finished
  while its steps were still queued shows a green dot beside "Waiting for sign-in". The switch is
  the exception and follows the real phase, since a click must be answered at once.
  Four phases skip the queue: `idle` and `contactingGateway` because they answer a click, `failed`
  and `reconnecting` because nobody sees news that waits. `connected` must not, or the end of a
  connect flushes every queued step and the dwell looks broken.
- **Only the working states shimmer**, meaning the four connect steps and reconnecting. Settled
  states (`idle`, `connected`, `failed`) are plain: a highlight crossing them says work is under way
  when none is. The shimmer is a gradient the glyphs are *filled* with, not a band drawn over them,
  and it is clock-driven (`TimelineView`), because an ancestor `.animation` re-applies its own curve
  to a `repeatForever` started in `onAppear` and kills it.
- **The row's height change springs, and the animation lives at the mutation.** `StatusPacer` wraps
  every change of `shown` in `withAnimation`. An `.animation(_:value:)` on the row animates only
  what that view draws; the height it reports to its parent, and the panel and popover sizing
  themselves off it, are laid out outside it, so the spring looked dead at every setting.
- No section headings inside the panel, and no account count. Adding lives in the footer's `+`
  menu, so the list starts at the top.
- **Say each thing once.** The VPN block titles the gateway; the account rows title the account.
  Both have shown the same address at different times, and it always read as a mistake. The tunnel
  group is not shown at all: it is fixed per connection and the editor already has it.
- Every way to add an account is declared once, in `AddMethod`, so the menu and the empty state
  cannot drift apart or offer something the other does not.
- **With no connection to dial, the VPN row offers Set Up, not a connect control.** Until
  `profile.isComplete`, the switch (or Connect button) is replaced by a Set Up button that opens
  Settings on the Connections tab. A disabled switch would say only that it cannot be used; this
  says what is missing and goes to the page that fixes it. The title reads "No connection" when
  nothing is saved, and **there is no status line at all in that state**: every wording of it
  either repeated the title or repeated the button, and "Not connected" invites waiting for a
  connection nothing will start. `VPNController.connect()` refuses an incomplete profile with a
  message saying so, since a keyboard shortcut can still reach it.

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
- Notifications are opt-in and cover state, not progress. The icon serves whoever is looking at
  the menu bar; a banner is for whoever is not, so connect, disconnect, trouble and the session
  being rebuilt are announced. One switch covers all of them: they are the same question asked
  several times, and the footnote under it names the moments, which is all a row per kind ever
  really said. The steps of a connect are not announced, the same event twice running says so
  once, and the launch state is never announced.
  **A renewal announces itself** (`VPNStatusEvent.renewing`, "VPN session renewing"), which
  reverses the original rule that it was silent unless it failed. It was reported as a bug, and
  rightly: for the seconds a renewal takes the machine really is off the VPN, so a gap nobody was
  told about reads as a fault. `isRenewing` still silences the steps in between, which is now all
  it does. The decision lives in
  `StatusNotificationPolicy`; `VPNStatusNotifier` only asks permission and posts. Every call into
  `UNUserNotificationCenter` is gated on the process being a real `.app`, since it traps in a
  bare executable, which is how `swift run` runs the app.
- **"Connected" is checked, not assumed.** openconnect's claim goes stale two ways, and neither
  reports itself: its process can be gone (a tunnel adopted from a previous launch has no output
  handler watching it), and its session can expire under a device that is still up, which is the
  state that read "Connected" beside a countdown saying "expired" while nothing got through. The
  heartbeat that redraws the countdown also asks `ReconnectPolicy.evaluateHealth`, so the worst
  case is one interval late rather than never. An expired session is torn down either way: left
  up it still holds the routes, including the default one, so the machine has no working network
  at all. A single long `Task.sleep` to the renewal lead is the optimisation, never the guarantee.
- **Only the current attempt may report.** A connect sequence and a runner each carry a
  generation, and anything stamped with an older one is dropped (`VPNController.report`,
  `apply(runnerState:generation:)`). An abandoned openconnect keeps printing until it dies and a
  cancelled sequence still unwinds through its catch blocks, so without this the tail of a
  torn-down tunnel set the phase behind the connect that replaced it: a renewal still on
  "Authenticating..." showed, and announced, "Connected".
- Connect flow: gateway init, `WKWebView` SAML login, auth-reply, spawn openconnect with
  `--cookie-on-stdin --servercert <pin>` and write the session token to stdin.
- Autofill injects email, password and TOTP into the IdP page from the Keychain.
  **Never fail closed:** if any selector does not match, show the login window and let the user
  finish by hand.
- Pin the gateway cert by SHA1. Do not disable TLS validation wholesale. The pin is learned on
  first contact (Detect, `TrustPolicy.learnFingerprint`) and enforced from then on; that one
  request is the only time an unknown certificate is accepted, and the user is shown what was
  learned.
- What was learned means the certificate, not just the hash. `PinnedCertificate.read` records
  both digests, the subject CN, the subjectAltName DNS list, the issuer, the validity window and
  the day it was pinned; the connection editor shows them the way Keychain Access would. Expiry
  is the one that earns its place: when the gateway renews, the pin stops matching and the
  failure looks like an attack unless the date already said a renewal was due.
  `certificateSHA1` stays the pin of record and `profile.certificate` is description only, so
  `profile.pinnedCertificate` withholds details that no longer hash to the pin rather than
  showing them as current. openconnect is still handed the SHA1; the SHA256 is recorded for the
  eye, and for `pin-sha256:` if `--servercert` is ever switched over.
- A connection is the whole combination: address, group, pin, username, password source and the
  authenticator account whose code fills the OTP field. Several can exist; one is selected, and
  the menu bar acts on that one. Credentials were briefly a list of their own and were folded
  back in: with one gateway it was an entity to keep straight rather than a saving.
- The group comes from a group-less init POST (`ConfigAuth.parseProbe`), never typed.
- Detect the openconnect binary at launch; if missing, say so plainly and point at
  `brew install openconnect`.
- **Setup the user must do by hand ships as a command to copy, never as "see the README."** A
  downloaded `.app` has no README beside it. `SetupCommands` builds both lines (the brew install and
  the sudoers drop-in) from the same constants `OpenConnectRunner` launches with, so a pasted rule
  cannot cover a path the app does not use, and the advice changes when Homebrew itself is absent
  rather than telling someone to run a command that will say "command not found". Settings also
  offers Locate, since only one machine in the world has openconnect exactly where the default
  looks.
- Disconnect must actually tear down the tunnel and restore routing.

## Features / Behavior (authenticator half)
- Menu bar dropdown lists each account with issuer, label, live code, and a shrinking progress ring/bar for the period.
- Click a code (or a copy button) runs `NSPasteboard.general.clearContents()` then `setString(code, forType: .string)`; show a brief "Copied" confirmation.
- **Add account:**
  - *QR:* let user capture a region of the screen (or drop an image); decode with Vision; parse `otpauth://`.
  - *Manual:* text fields for issuer, account, and Base32 secret.
- An enrolled account is read-only. Every field of it changes what code comes out, and a wrong
  one produces plausible but useless codes with nothing on screen to say why, so Details shows
  it and changing anything means deleting and scanning again.
- Codes refresh every second; recompute on each period boundary.
- Delete account with confirmation, which also removes it from the Keychain.

## In-app updates (Sparkle)
The app updates itself from `appcast.xml` at the root of this repo, served raw from `main`. About
has the Check Now button and the automatic-checks switch; `UpdateController` owns the one
`SPUStandardUpdaterController` for the process.

- **The signature is the trust, not the transport.** Every release zip is signed with an EdDSA key
  whose public half is `SUPublicEDKey` in the Info.plist, and Sparkle refuses anything that key
  does not verify. That is what makes an unnotarised zip fetched over
  `raw.githubusercontent.com` safe to install. **`SUPublicEDKey` is a storage address, like the
  bundle id and the Keychain services:** replacing the key strands every copy already installed,
  because those copies verify against the old one.
- **Background checks are refused while a tunnel is up or being built.** Installing an update
  restarts the app, and quitting takes openconnect down with it, so a scheduled check that
  surfaced an update mid-session would offer a button that drops the user's connection. A check
  the user asked for is allowed: they are there, and Sparkle asks before installing. The gate is a
  closure installed by `StatusItemController`, so the updater never has to know what a tunnel is.
- **Sparkle's windows go through `WindowActivation`,** never `setActivationPolicy` directly. An
  `.accessory` app cannot take key focus, so an alert would open unfocused behind whatever is in
  front; claiming and releasing through the one place that derives the policy from open windows is
  what keeps Settings-open-behind-Sparkle from leaving the app `.regular` forever.
- **Nothing starts under `swift run`.** Sparkle reads the feed URL and the public key from the
  Info.plist, and a bare executable has none, so `start` returns early and About says the feature
  is unavailable rather than offering a button that does nothing. Same `isBundled` test as
  `VPNStatusNotifier`, for the same class of reason.
- SwiftPM links the framework but cannot embed one, so `Scripts/make-app.sh` copies
  `Sparkle.framework` into `Contents/Frameworks`, checks the rpath and both architectures, and
  signs the four nested programs inside out before the app. `Scripts/update-appcast.py` writes the
  feed entry from the release workflow.

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
- **The bundle identifier, the two Keychain services, and the `autoconnect.` defaults prefix are
  storage addresses, not labels.** Changing any of them points the app at empty storage, and the
  accounts read as deleted. The rename from MacAuth changed all four at once, which is what
  `LegacyMigration` exists to absorb; anything similar needs the same treatment.
- **Prefer the real Apple Development identity over `SIGN_IDENTITY="-"`.** A Keychain item's ACL
  and a TCC grant both trust one exact code signature, and every ad-hoc rebuild produces a new
  one. The app then re-asks for the login Keychain password and for Documents access on every
  launch, and "Always Allow" only holds until the next build. This is worth saying out loud when
  the user asks why a prompt keeps coming back: it is the build, not their machine.
- **Quit the app before running `Scripts/make-app.sh`.** It starts with `rm -rf build/AutoConnect.app`,
  and replacing the bundle under a running process invalidates that process's code signature.
  The Keychain then refuses the ACL check, so every code renders as `------` while the account
  names still load, because attribute reads survive and `secret(for:)` does not. It looks like
  lost secrets and is not: quit, rebuild, reopen.
- **An ad-hoc signature must not carry the hardened runtime, now that a framework is embedded.**
  The hardened runtime turns on Library Validation, which demands that every library loaded into
  the process share the main binary's Team ID, and an ad-hoc signature has no Team ID at all. The
  app then dies in `dyld` before any code runs, with "Library not loaded:
  @rpath/Sparkle.framework/... have different Team IDs". `make-app.sh` drops the flag for ad-hoc
  and keeps it for a real identity, where the app and Sparkle are signed alike. Do not "restore"
  it for consistency: the sibling app shipped two releases that could not start this way.
- **`otool ... | grep -q` is a trap under `set -o pipefail`.** grep exits at the first match, otool
  dies of SIGPIPE, and the pipeline reports failure while the thing being looked for is right
  there. Capture the output first, then match it. Both the rpath check in `make-app.sh` and the one
  in the release workflow were written this way and reported a missing rpath that was present.
- Verified toolchain on this machine: macOS 26.5.1, Xcode 26.6, Swift 6.3.3, arm64.

## Definition of Done

Authenticator (done, verified against the user's live accounts):
- [x] TOTP unit tests pass against all RFC 6238 Appendix B vectors (SHA1/256/512).
- [x] Base32 decoder handles padding, lowercase, spaces, hyphens, impossible lengths.
- [x] Can add an account by scanning the screen, by image, or by pasted link. Every path reads
      the issuer's QR code; typing a Base32 seed by hand was offered and removed.
- [x] Live code + per-account countdown render in the panel.
- [x] One-click copy with visual confirmation.
- [x] Secrets persist across launches via Keychain; delete removes them.
- [x] Codes match the user's existing authenticator.

VPN connector:
- [x] `ConfigAuthXML` parses captured real init and auth-reply responses in unit tests.
- [x] Cert pinning by SHA1, cross-checked against the fingerprint the gateway reports.
- [x] The pin is shown as a certificate: names, issuer, expiry, both digests, first pinned on.
      Parsed from a real DER fixture in tests, not from a hand-written dictionary.
- [x] Menu bar shows state, gateway, assigned IP, session countdown, and statistics.
- [x] Statistics parse real `netstat` output; throughput chart with shared scale.
- [x] Shutdown targets this app's own process only, never a bare `openconnect` name match.
- [x] Missing openconnect binary produces a clear, actionable message.
- [x] Settings: General / Connections / Authenticator, with a connection list.
- [x] Status notifications, off by default, behind one switch that covers connect, disconnect
      and reconnect. Which transitions are news is pure and tested.
- [x] Nothing about any gateway is compiled in: Detect reads its groups and pins its cert.
- [x] Reconnect decisions are pure and tested (renewal lead, backoff, give-up, network change,
      and the health of a tunnel that claims to be connected).
- [x] **Connects end to end and brings up a working tunnel with corporate DNS.** Verified live on
      2026-08-21: `utun6` at `10.250.232.17`, default route through it, nameservers `172.30.6.21`
      and `172.30.6.22`. The four steps, the pin check and the sudo spawn all hold against the
      real gateway.
- [x] Autofill completes a connect with zero typing: username, password and OTP all injected, the
      token captured, and no field touched by hand.
- [x] Falls back to the visible window when a selector does not match. The rule is still fail-open,
      and the window is already on screen with the field waiting.
- [x] Adopts a tunnel left running by a previous launch, and now starts the renewal, the network
      monitor and the wake observers for it, which it did not before.
- [x] Disconnect tears down the tunnel and restores routing. Verified live.
- [x] Auto-reconnect near expiry works in practice. `ReconnectPolicy.evaluateHealth` answers the
      two ways "connected" goes stale (process gone, session expired), and the renewal rebuilds
      the session without announcing itself as a disconnection.

Updates:
- [x] Sparkle embedded, signed inside out, and verified for both architectures by the build script.
- [x] About shows the version, a Check Now button, the automatic switch, and the last check.
- [x] Background checks are refused while a tunnel is up; a manual check is not.
- [x] The release workflow signs the zip and commits the feed entry, or fails the release.
- [ ] **An update installs end to end**, meaning a real release is offered to an older copy and
      replaces it. Needs two releases to exist and `SPARKLE_PRIVATE_KEY` to be set on the repo.

**The one thing left is B6, the privileged helper, and it is optional.** Everything else in the
connector has now been run live: connect, zero-typing autofill, disconnect, and renewal at expiry.
Root still comes from the sudoers rule, which Settings installs, detects and removes for the user
(`SetupCommands`) rather than pointing at a README. `SMAppService` is used here only for the login
item, not for a helper. A live connect or disconnect still needs asking first, because the session
at risk is the one the user is working over.

## Working Style for Claude Code
- **Read `plan.md` first.** Follow its phase order. It exists so the gateway protocol and the
  discovered facts are not rediscovered every session.
- **Never connect, disconnect, or kill a VPN process without explicit permission.** The user
  routinely has their own openconnect running and depends on it; taking it down loses their work.
  Read-only inspection (`netstat`, `ifconfig`, `scutil --dns`, `pgrep`) is fine.
- Get a manual path working before automating it. Autofill is the most fragile part and must never
  be the only path: when a selector does not match, show the window and let the user finish.
- Capture real gateway and IdP responses as test fixtures, with secrets redacted. The parsers exist
  to handle the bytes Cisco actually sends, not an idealised version.
- Put testable logic in `AutoConnectCore`, not the app target, and never duplicate a type into a test
  file to make it reachable.
- Use the playground for UI work instead of connecting. Preview controllers must never touch the
  machine: a mock that polls reads the user's real tunnel, which has already happened once.
- Commit in small, working increments. Explain any deviation from this spec.
- Ask before adding any external dependency.

## Playground convention
Dev-only tuning windows follow the pattern in `Sources/AutoConnect/Playground/`: an `@Observable`
params object the shipping views read, a `Codable` snapshot decoded key-by-key with defaults
(never the synthesized decoder, or adding a knob discards the saved set), a mock stage rendering
the real views, and a controls sidebar. Sliders snap by rounding inside the binding, never with
`Slider(step:)`, which draws tick marks. Only expose knobs that cannot be judged from a static
screenshot; measured constants stay constants.

Four more rules, each one paid for:

- **Never build the mock objects inside `body`.** Build them in `onAppear` and `onChange(of:
  params.signature)` and hold them in `@State`. Building them per body pass span the app to 59% CPU
  and 565MB and climbing: each pass made a fresh `AppState`, each with its own one-second ticker,
  and every tick invalidated the view that had just created it. A pegged main thread also stops the
  status item from ever drawing, so the symptom reads as "the menu bar icon is missing".
- **The playground is an app-owned `NSWindow` (`PlaygroundWindow`), not a SwiftUI `Window` scene.**
  A scene restored itself at launch after any session that had opened it, and an accessory app
  cannot raise a restored window because it cannot become active. Presenting it also needs
  `canJoinAllSpaces`, `fullScreenAuxiliary` and `orderFrontRegardless`, or with a full-screen app
  in front the window lands on the desktop Space and is invisible behind it.
- **The only way in is the launch flag:**
  `build/AutoConnect.app/Contents/MacOS/AutoConnect --playground` (DEBUG only). The panel's footer
  button is gone; it was never usable by UI scripting anyway, because a popover in an accessory app
  is not exposed to accessibility at all.
- **Mock controls must do something.** Connect, Disconnect and the switch route through
  `VPNController.onPreviewConnectRequest` and walk the stage through the real phase sequence
  (`PhaseScripter`, 700ms a step). Note the guard this depends on: `connect()` and `disconnect()`
  return early for previews. Before that guard existed, Connect in the playground really did start
  a webview sign-in and openconnect against the example gateway, and Disconnect could have torn
  down the user's live tunnel.
- A knob that no longer drives anything is worse than no knob: it invites tuning a value the app
  has stopped reading. When a feature goes (the dot's pulsing halo, for instance), its knobs go with
  it, and a value that has settled gets baked into the view as a constant.
- **A knob that cannot apply is removed from the sidebar, not dimmed.** State's Connection picker
  (`PreviewConnection`: Configured or None) covers the empty state, and None takes the Phase
  picker and its fake tunnel fields away with it, the way Switch size only appears while the
  switch is the control in use. There is no half-configured choice: two states are the design
  question, and a third only made the picker something to read.
