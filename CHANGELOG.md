# Changelog

Every notable change to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

### Added

- **All Actions** in the menu bar panel (and the right-click menu): every conversion, tool and action, browsable by
  kind of file, with a one-line description of each tool and action and the reason a dimmed one can't run yet.
  Choosing an entry runs it on the Finder selection, or asks for the files it works on.

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

[Unreleased]: https://github.com/organetto8/Kumquat/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/organetto8/Kumquat/releases/tag/v1.0.0
