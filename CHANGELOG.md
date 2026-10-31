# Changelog

Every notable change to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

## [1.1.0-beta.1] - 2026-10-31

### Added

- **Search or browse all actions** in the menu bar panel: every conversion, tool and action on a page of the
  panel, browsable by kind of file or found by typing, with a one-line description of each tool and action and
  the reason a dimmed one can't run yet. Choosing an entry runs it on the Finder selection, or asks for the files
  it works on. The right-click menu has the same catalogue under **All Actions**.
- Automatic updates from GitHub releases, once a day or from **⋯ ▸ Check for Updates…** in the menu bar panel,
  with betas as an option (Settings ▸ General ▸ Updates). An update you put off waits in the panel as **Install
  Kumquat x.y.z and Relaunch**, and none is installed while a job or an engine install is running. An update is
  installed only if it carries the release key's Ed25519 signature, is newer than the installed version and keeps
  an intact code signature; Kumquat never asks for a password to install it. This check, which can be turned off,
  and **Install** in Settings ▸ Engines are the only times Kumquat goes online.
- **Install** buttons in Settings ▸ Engines: Kumquat downloads its own build of a missing engine (FFmpeg,
  WebP, JPEG XL, potrace, pandoc, Calibre, 7-Zip, WOFF2, fontTools) from its engines release on GitHub, checks
  it against a SHA-256 built into the app and unpacks it in Application Support. No Homebrew or password
  needed; Homebrew is used when the pack has nothing for the Mac. Pages, Keynote and Numbers open in the App
  Store. **Copy Command** moved to the right-click menu, and dimmed options in the wheels and in All Actions now
  point to Settings ▸ Engines.
- The engine pack itself: `Scripts/engines/build.sh` and the Engines workflow build every engine for Apple
  silicon and Intel and publish them as an `engines-N` release.

### Changed

- Clicking the menu bar icon opens a panel instead of a plain menu: Convert, Edit and Send as large tiles you
  click for the Finder selection or drop files on, the wheel keys and shortcut at a glance, the Basket, the main
  switches, Settings and help. Holding a file drag on the icon opens the panel too. Right-click still shows the menu.

### Fixed

- The Welcome window wraps long lines instead of cutting them off, so the Italian instructions are readable
  in full ([#2](https://github.com/organetto8/Kumquat/issues/2)).

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

[Unreleased]: https://github.com/organetto8/Kumquat/compare/v1.1.0-beta.1...HEAD
[1.1.0-beta.1]: https://github.com/organetto8/Kumquat/releases/tag/v1.1.0-beta.1
[1.0.0]: https://github.com/organetto8/Kumquat/releases/tag/v1.0.0
