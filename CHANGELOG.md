# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries accumulate under [Unreleased] as work lands, and move into a versioned
section when a release is cut.

## [Unreleased]

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

