# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries accumulate under [Unreleased] as work lands, and move into a versioned
section when a release is cut.

## [Unreleased]

## [1.6.0] - 2026-08-30

### Added
- The menu bar panel now shows a live countdown to the next automatic reconnection attempt, with the attempt number and the reason the last one failed. A drop with no internet says "Waiting for network" instead of sitting silently on "Failed".

### Fixed
- A tunnel that openconnect drops and rebuilds by itself in under a few seconds no longer posts a bare "VPN connected" banner out of nowhere. A drop now waits three seconds before it is announced, so a blip the tunnel settles on its own passes in silence, and a real outage still says it is reconnecting before it says it is back.
- A tunnel that dropped while automatic retries were queued no longer reads as "Failed". That state is now reserved for the point where the app has really stopped trying, and a transient drop no longer posts a "VPN failed" notification ahead of the reconnection one.

## [1.5.0] - 2026-08-23

### Changed
- Automatic retries now allow six attempts, backing off 30s, 1m, 2m, 4m and 8m, so a recovery window of about a quarter of an hour outlasts a Wi-Fi handover or a captive portal. Attempts made while there is no network at all are held rather than counted.

### Fixed
- Automatic reconnection no longer gives up during a brief network outage. A recovering network is reported several times over, and each report was counted as a failed retry while also cancelling the retry the previous one had queued, so the budget ran out after roughly ninety seconds without a single attempt having been made. Only an attempt that was really made and really did fail now counts.
- The app no longer declares a connection failed while openconnect is recovering the tunnel on its own. Its own retries keep the session and usually succeed, so they are now waited out rather than taken over.
- A connect attempt that fails before the tunnel starts, a gateway that times out being the ordinary case, now schedules a retry instead of simply stopping.

## [1.4.2] - 2026-08-23

### Fixed
- Scanning a QR code with the camera crashed the app immediately. The camera was being asked for barcode types macOS does not offer, which threw an error Swift cannot catch; decoding now goes through Vision, the same way the screen and image paths already did.
- Camera scanning was blocked outright on a signed build, reporting that macOS was blocking the camera with nothing to switch on in System Settings. The app now carries the camera entitlement the hardened runtime requires.
- The camera permission prompt could open behind the scan window, leaving a black window that never did anything. Permission is now settled before the window appears.

## [1.4.1] - 2026-08-23

### Added
- Scan an authenticator QR code with the Mac's camera, alongside the existing screen, image and pasted-link paths.
- Google Authenticator export QR codes (otpauth-migration://), which carry several accounts at once.

### Fixed
- A backticked "swift run" in the Info.plist heredoc hung the build.

## [1.3.0] - 2026-08-21

### Changed
- A session renewal near expiry now announces itself as renewing. It used to be silent unless it failed, which read as an unexplained gap in connectivity.

### Fixed
- Auto-reconnect rebuilds the session at expiry instead of reporting it as a disconnection.

## [1.2.0] - 2026-08-20

### Changed
- Status notifications are now a single switch covering connect, disconnect and reconnect, instead of one row per kind.

### Removed
- Typing a Base32 secret by hand. Every account is now added by reading the issuer's QR code, because a mistyped character produces plausible codes that are silently rejected.

## [1.1.0] - 2026-08-19

### Added
- In-app updates through Sparkle, with a Check Now button and an automatic-checks switch in About. Background checks are refused while a tunnel is up.

