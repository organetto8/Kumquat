# Changelog

Every notable change to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

## [1.1.0] - 2026-11-05

Everything from the 1.1.0 betas, for anyone coming from 1.0.0. Since 1.1.0-beta.3, only the disk image and
wheel drop fixes below are new.

### Added

- **Search or browse all actions** in the menu bar panel: every conversion, tool and action on a page of the
  panel, browsable by kind of file or found by typing, with a one-line description of each tool and action and
  the reason a dimmed one can't run yet. Choosing an entry runs it on the Finder selection, or asks for the files
  it works on. The right-click menu has the same catalogue under **All Actions**.
- **Wi-Fi Receive** in the Send wheel: drop a folder and scan its QR code with a phone on the same network to
  send photos, videos or any file straight into that folder. Names already taken get " 2" as in Finder,
  received files are marked as downloaded like AirDrop's, and the window lists what arrived.
- **Setup window** at first launch, in three pages: what Kumquat does, the optional extras, and how the
  wheels work. The extras page lists every engine with what it adds and its download size, the small
  recommended ones (FFmpeg, WebP, JPEG XL, potrace, 7-Zip, WOFF2: about 22 MB) already ticked;
  **Install and Continue** downloads them while you read on. Pages, Keynote and Numbers get App Store links.
- People who already went through the old welcome window get a one-time card in the menu bar panel that
  opens the extras page.
- **Install** buttons in Settings ▸ Engines: Kumquat downloads its own build of a missing engine (FFmpeg,
  WebP, JPEG XL, potrace, pandoc, Calibre, 7-Zip, WOFF2, fontTools) from its engines release on GitHub, checks
  it against a SHA-256 built into the app and unpacks it in Application Support. No Homebrew or password
  needed; Homebrew is used when the pack has nothing for the Mac. Pages, Keynote and Numbers open in the App
  Store. Installs run two downloads at once, show their overall progress in the menu bar panel, resume at the
  next launch when Kumquat quits halfway, and stop before downloading when the disk is too full to unpack them.
  **Copy Command** moved to the right-click menu, and dimmed options in the wheels and in All Actions now
  point to Settings ▸ Engines.
- **Install Recommended** in Settings ▸ Engines.
- **Update Extras** in the menu bar panel, and **Update** in Settings ▸ Engines, when the app installs from a
  newer engine pack than the one an engine came from.
- The engine pack itself: `Scripts/engines/build.sh` and the Engines workflow build every engine for Apple
  silicon and Intel and publish them as an `engines-N` release.
- Automatic updates from GitHub releases, once a day or from **⋯ ▸ Check for Updates…** in the menu bar panel,
  with betas as an option (Settings ▸ General ▸ Updates). An update you put off waits in the panel as **Install
  Kumquat x.y.z and Relaunch**, and none is installed while a job or an engine install is running. An update is
  installed only if it carries the release key's Ed25519 signature, is newer than the installed version and keeps
  an intact code signature; Kumquat never asks for a password to install it. This check, which can be turned off,
  and **Install** in Settings ▸ Engines are the only times Kumquat goes online. From 1.0.0 this version has to be
  installed by hand once; later ones arrive by themselves.

### Changed

- Clicking the menu bar icon opens a panel instead of a plain menu: Convert, Edit and Send as large tiles you
  click for the Finder selection or drop files on, the wheel keys and shortcut at a glance, the Basket, the main
  switches, Settings and help. Holding a file drag on the icon opens the panel too. Right-click still shows the menu.

### Fixed

- The Welcome window wraps long lines instead of cutting them off, so the Italian instructions are readable
  in full ([#2](https://github.com/organetto8/Kumquat/issues/2)).
- Making, opening or checking a disk image no longer fails with "Resource temporarily unavailable" when macOS's
  disk image service is still busy with the previous one: Kumquat waits up to about 15 seconds and tries again.
- Dropping files on a wheel action that opens a window or menu of its own (Move, Copy To, Rename…) no longer
  leaves drags and gestures stuck until that window closes.

## [1.0.0] - 2026-10-30

First public release.

### Added

- **Convert** wheel (⇧): about 1,190 conversions across images, video, audio, PDF, documents, presentations,
  spreadsheets, data, subtitles, archives, fonts and 3D models, including speech to subtitles and documents read aloud.
- **Edit** wheel (⌘): 73 tools, from compress, trim and crop to OCR, background removal, PDF signing and redaction,
  translation and summaries.
- **Send** wheel (⌃): 27 actions, including AirDrop, Wi-Fi Share to a phone, the Basket shelf, favourite folders,
  Shortcuts and your own scripts.
- Keyboard shortcut ⌃⌥K for the Finder selection, Finder Services, drops on the menu bar icon, and the
  `--run` / `--wheel` command line.
- English and Italian.
- **Copy Diagnostic Info** in the menu bar menu, for bug reports.

[Unreleased]: https://github.com/organetto8/Kumquat/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/organetto8/Kumquat/releases/tag/v1.1.0
[1.0.0]: https://github.com/organetto8/Kumquat/releases/tag/v1.0.0
