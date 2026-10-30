# Changelog

Every notable change to Kumquat. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
and versions follow [Semantic Versioning](https://semver.org/). How releases are made: [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

### Added

- **Install** buttons in Settings ▸ Engines: Kumquat downloads its own build of a missing engine (FFmpeg,
  WebP, JPEG XL, potrace, pandoc, Calibre, 7-Zip, WOFF2, fontTools) from its engines release on GitHub, checks
  it against a SHA-256 built into the app and unpacks it in Application Support. No Homebrew or password
  needed; Homebrew is used when the pack has nothing for the Mac. Pages, Keynote and Numbers open in the App
  Store. **Copy Command** moved to the right-click menu, and dimmed wheel options now point to Settings ▸ Engines.
- The engine pack itself: `Scripts/engines/build.sh` and the Engines workflow build every engine for Apple
  silicon and Intel and publish them as an `engines-N` release.

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
