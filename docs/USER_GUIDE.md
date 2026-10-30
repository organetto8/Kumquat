# Kumquat user guide

Kumquat lives in the menu bar and converts or edits files without sending them anywhere. This guide covers
installing it, the three wheels, settings, and what to do when something does not work.

- [1. Install](#1-install)
- [2. First launch](#2-first-launch)
- [3. Using the wheels](#3-using-the-wheels)
- [4. Other ways to start a job](#4-other-ways-to-start-a-job)
- [5. What each wheel offers](#5-what-each-wheel-offers)
- [6. Where results are saved](#6-where-results-are-saved)
- [7. Audio, video and iWork support](#7-audio-video-and-iwork-support)
- [8. Settings](#8-settings)
- [9. Permissions](#9-permissions)
- [10. Updating and uninstalling](#10-updating-and-uninstalling)
- [11. Troubleshooting](#11-troubleshooting)

---

## 1. Install

You need macOS 14 Sonoma or later. The download runs natively on Apple silicon and Intel Macs.

1. Go to the [latest release](https://github.com/organetto8/Kumquat/releases/latest) and download
   `Kumquat-x.y.z.dmg`.
2. Double-click the DMG. A window opens with Kumquat and an Applications folder.
3. Drag **Kumquat** onto **Applications**.
4. Eject the disk image (the ⏏ button next to it in the Finder sidebar).

Prefer a ZIP? Download `Kumquat-x.y.z.zip` instead, double-click it, and move `Kumquat.app` to Applications.

To check that the download is intact, compare its checksum with `SHA256SUMS.txt` from the same release:

```bash
shasum -a 256 ~/Downloads/Kumquat-*.dmg
```

## 2. First launch

Kumquat is free and not notarised by Apple, so macOS asks for confirmation the first time.

**macOS 15 Sequoia and later**

1. Open Kumquat from Applications. macOS says it cannot verify the app. Click **Done**.
2. Open **System Settings ▸ Privacy & Security**.
3. Scroll to the Security section. Next to *"Kumquat" was blocked*, click **Open Anyway**.
4. Confirm with **Open Anyway** and your password or Touch ID.

**macOS 14 Sonoma**

1. In Applications, right-click (or Control-click) Kumquat and choose **Open**.
2. Click **Open** in the dialog.

**Terminal alternative (any version)**

```bash
xattr -dr com.apple.quarantine /Applications/Kumquat.app
```

You only do this once. Afterwards Kumquat opens like any other app.

When it starts, a kumquat icon appears in the menu bar and the welcome window shows the basics. Tick
**Launch at login** there if you want Kumquat available all the time. You can reopen the welcome window
later from the menu bar icon ▸ **How Kumquat Works**.

## 3. Using the wheels

A wheel is a round menu that opens under the pointer while you are dragging files.

1. In Finder, press on one or more files (or a folder) and start dragging. Keep the mouse button down.
2. Tap a wheel key:
   - **⇧ Shift** for **Convert**
   - **⌘ Command** for **Edit**
   - **⌃ Control** for **Send**
3. Release the key. The wheel stays open while you keep holding the files.
4. Move over a slice and let go of the mouse button. The job starts.

To cancel, drop in the middle of the wheel or anywhere outside it.

While a job runs, a small card in the top-right corner shows its progress. When it finishes, click
**Show** to reveal the new file in Finder.

The wheel only shows what makes sense for the files you are holding. Several files of the same kind are
processed together, in parallel. Options that need a missing program are dimmed, with a hint on what to
install.

### Tool options

Some tools need a detail before they start: trim points, how many parts to split into, a password,
watermark text, a new size. Kumquat asks in a small panel with sliders and buttons, already filled in with
the values you used last time. Press **Return** to accept or change them first. **Reset** brings back the
defaults.

Other tools run straight away (Compress, Flip, Make GIF, Normalize), using the options you
picked last time. The wheel's centre tells you which is which: **Instant · ⌥ options** or **Options · ⌥ skips**.

- Hold **⌥ Option** as you drop to show the options of an instant tool, or to skip the panel of the others
  and reuse your last values. Passwords are always asked for.
- **Trim**, **Speed**, **Crop** and **Make GIF** on a video open a preview of the first clip. Drag the
  orange handles under it to choose start and end, watch it play at the chosen speed, or drag the frame
  over the video to choose the area to keep (pick a shape such as 9:16 to lock it). MKV, WebM, AVI, WMV
  and GIF clips take a moment to prepare first. **Rotate** turns the preview as you pick a direction;
  MP4 and MOV only get a new rotation flag (instant, no quality loss), other formats are re-encoded.
- **Crop** and **Rotate** on an image or PDF show the first picture (or the first page). Crop: **Auto**
  trims plain borders or white margins; **Free** or a shape (1:1, 4:3, 3:2, 16:9, 9:16, 4:5) lets you
  drag the frame. On a PDF the area drawn on the first page applies to every page. Rotate: pick ↺, ↻ or
  180°, and on images drag **Straighten** (−45° to 45°) to level a horizon; any tilt crops the corners
  away so none are left empty. Quarter turns of JPEG, HEIC and TIFF stay lossless.
- **Compress** offers a quality level, a size limit for video (for example 25 MB) and a bitrate for audio.
  **Flip** goes horizontal or vertical, and **Watermark** has opacity and
  direction.

## 4. Other ways to start a job

| Method | How |
|---|---|
| Keyboard | Select files in Finder and press **⌃⌥K**. The Convert wheel opens. Arrow keys move, **Return** applies, **Esc** cancels, the wheel keys switch wheel. |
| Menu bar | Drop files on the kumquat icon, or open its menu and choose **Convert / Edit / Send Finder Selection…** |
| Finder Services | Right-click files ▸ **Services ▸ Convert with Kumquat**. |
| Terminal | `/Applications/Kumquat.app/Contents/MacOS/Kumquat --run convert:png photo.heic` runs a job directly. `--wheel tools clip.mp4` opens a wheel for the file. |

`--run` accepts `convert:<format>` (for example `convert:mp4`), `tool:<tool>` (for example `tool:compress`)
and `action:<action>` (for example `action:copy`). Tools run with the options you used last.
`--options <tool> <files…>` (for example `--options trim clip.mp4`) shows a tool's options panel instead.
`--diagnostics` prints the same text as **Copy Diagnostic Info** and quits, handy for bug reports.

## 5. What each wheel offers

Long wheels show their first eleven choices and a **More** segment. Rest the dragged files on **More** (or
click it, or press Return on it) to turn to the next page.

### Convert (⇧)

Shows the formats the selected files can become. The full table is in the
[README](../README.md#supported-formats). Some highlights:

- Photos: HEIC, JPG, PNG, WebP, AVIF, TIFF, BMP, PDF, GIF, JPEG XL, ICO, ICNS, JPEG 2000, SVG; camera RAW,
  Photoshop, TGA and EXR files open too
- Video: MP4, MOV, MKV, WebM, AVI, WMV, GIF, animated WebP, the audio alone, or **subtitles of what is said**
  (SRT, VTT, TXT), recognised on this Mac; camcorder and old formats (MTS, TS, MPG, VOB, 3GP, FLV, OGV) open too
- Audio: MP3, M4A, WAV, FLAC, Ogg, Opus, AIFF, WMA, M4B audiobooks, CAF, AC3, iPhone **Ringtone**, an MP4 with
  a moving waveform for social networks, or a transcript
- PDF: Word, Pages, PowerPoint, Excel, images, EPUB, text, Markdown, HTML, RTF, ODT, TIFF, CSV tables, or an
  M4A that reads it aloud
- Documents: DOCX, Pages, Markdown, TXT, EPUB, HTML, PDF, RTF, ODT, DOC, LaTeX, reStructuredText, AsciiDoc,
  Org, Kindle (MOBI, AZW3), or an M4A that reads it aloud
- Spreadsheets: XLSX, ODS, CSV, TSV, PDF, JSON, a Markdown or HTML table, SQLite; contacts (vCard) and
  calendars (iCal) from a sheet
- Data: JSON, YAML, XML, plist and TOML to each other; SQLite, vCard and iCal to sheets
- Subtitles: SRT, VTT, ASS/SSA, SBV, TTML, LRC, TXT
- Archives: ZIP, TAR, TAR.GZ, TAR.XZ, TAR.BZ2, 7Z, DMG (RAR opens too)
- Fonts: TTF, OTF, WOFF, WOFF2 · 3D models: OBJ, STL, PLY, USDZ, USD

When a video already uses codecs the target format supports, Kumquat repackages it instead of re-encoding,
so the conversion takes seconds and loses no quality.

### Edit (⌘)

| Files | Tools |
|---|---|
| Images | Compress, Crop, Resize, Rotate, Flip, Remove BG, Strip Metadata, OCR, Read QR, Merge, Scan, Blur Faces, Frame, Enhance, Filters, Palette, Icon Set, Watermark, Auto Tag |
| Video | Trim, Crop, Rotate, Compress, Split, Merge, Mute, Extract Audio, Speed, Resize, Frames, Make GIF, Vertical, Subtitles, Get Subtitles, Poster, Contact Sheet, Soundtrack, Reverse, Fade, Stabilize, Flip, Watermark, Denoise |
| Audio | Trim, Split, Merge, Compress, Normalize, Volume, Cut Silence, Denoise, Speed, Fade, Tags, Waveform, Channels |
| PDF | Merge, Split, Compress, Crop, Extract Pages, Rotate, Password, Watermark, OCR, Pages, Sign, Redact, Page Numbers, Flatten, 2-Up, Get Images, Grayscale, Strip Metadata, Summarize, Translate, Word Count |
| Documents | Merge, Split, Word Count, Replace, Clean, Translate, Summarize, Compress |
| Presentations | Compress, Notes & Media |
| Spreadsheets | Merge, Split, Excel CSV, Dedupe, Column Stats, Transpose, Compress |
| Subtitles | Shift Timing, Merge, Frame Rate, Clean, Translate |
| Archives | Extract, Encrypt, Volumes, Verify |
| Folders | Sort, Duplicates, Flatten, File List |

Every file and folder also gets **Lock** (a password-protected disk image that opens on any Mac) and **Zip**.

- **Remove BG** cuts the subject out of a photo and saves a PNG with a transparent background.
- **OCR** on an image copies the text it finds to the clipboard. On a scanned PDF it saves a searchable
  copy, `document (searchable).pdf`.
- **Read QR** copies the content of any QR code or barcode in an image to the clipboard.
- **Strip Metadata** removes location, camera and other hidden details from a photo, or only the location.
  On a PDF it sets or removes the title and author.
- **Merge** on photos makes one PDF, a long strip, a grid or an animated GIF.
- **Scan** straightens the photo of a sheet of paper or a receipt into a clean scan.
- **Blur Faces** finds faces and pixelates them, or hides an area you draw.
- **Frame** puts a screenshot on a coloured background with margins, rounded corners and a shadow.
- **Palette** saves the main colours as a swatch and copies their HEX codes.
- **Icon Set** turns a 1024 px picture into a macOS `.icns` and `.iconset`, and web icons (favicon, Apple
  touch icon, PWA icons).
- **Auto Tag** adds Finder tags describing the photo (beach, dog, document…), so Spotlight finds it.
- **Vertical** fits a landscape video into 9:16 for Reels, Stories and TikTok, over a blurred copy.
- **Subtitles**: drop a video together with its `.srt` or `.vtt`, then choose to burn them into the picture or
  add a track viewers can switch on. **Soundtrack** works the same way with a music file, replacing the sound
  or mixing the music underneath.
- **Poster** saves the frame under the playhead as a JPG, or sets it as the video's cover.
- **Compress** on a video can aim for WhatsApp, Instagram, Discord or email: the size, resolution and codec
  are chosen for you. On Word, PowerPoint and Excel files it shrinks the pictures inside.
- **Cut Silence** shortens long pauses in lectures, voice notes and podcasts.
- **Tags**: drop an image with the audio files to set it as their cover.
- **Pages** shows every page of a PDF: drag to reorder, ⌫ deletes, R turns a page.
- **Sign** places your signature, drawn once with the trackpad or imported from a photo, where you drag the box.
- **Redact** really removes the words, emails, IBANs or phone numbers you choose: pages with a match become
  images with black boxes, so the text cannot be copied back.
- **Translate** uses the languages downloaded in System Settings ▸ General ▸ Language & Region (macOS 26).
  Subtitles keep their timing.
- **Summarize** writes a Markdown summary with Apple Intelligence, on this Mac (macOS 26, Apple Intelligence on).
- **Excel CSV** writes a CSV that Excel opens correctly with Italian and other European settings
  (semicolons, decimal commas, accents intact).
- **Frame Rate** fixes subtitles that slowly drift out of sync (23.976 ↔ 25 fps).
- **Sort**, **Duplicates** and **Flatten** work inside the folder you drop: Sort makes subfolders by kind or
  month, Duplicates moves repeated files into a `Duplicates` folder (nothing is deleted), Flatten brings
  every file up out of its subfolders.

### Send (⌃)

| Action | What it does |
|---|---|
| AirDrop | Opens the AirDrop panel with the files. |
| Basket | Parks the files in a small floating basket. Drag them out again later, into any app. Closing the basket never touches the files. |
| Copy | Copies the files to the clipboard, ready to paste in Finder or any app. |
| Move | Moves the files to a favourite or recent folder, or one you pick. |
| Copy Path | Copies the full paths to the clipboard. |
| Terminal | Opens a Terminal window in the files' folder. |
| Share | The system share menu: Messages, Mail, Notes, Reminders and other apps. |
| Quick Look | Previews the files without opening an app. |
| Open With | Lists the apps that open the file, the default one first. |
| Copy Contents | Copies the picture itself, or the text of a document, PDF or subtitle file, ready to paste in a chat. |
| Rename | Renames in series with `{name}`, `{n}`, `{date}` and `{taken}` (when a photo was taken). |
| Trash | Moves the files to the Bin, as Finder does. |
| Copy To | Copies the files to a favourite or recent folder, or one you pick. |
| Duplicate | Makes a copy next to the original. |
| New Folder | Puts the files in a new folder, like Finder's New Folder with Selection. |
| Tag | Adds or removes a Finder colour tag. |
| Mail | A new message with the files attached. |
| Wi-Fi Share | Shows a QR code: scan it with any phone on the same network to download the files. Nothing goes to the internet; sharing stops when you close the window or after 15 minutes. |
| Print | Prints PDFs, pictures, documents and spreadsheets in one go. |
| Wallpaper | Sets the picture as the desktop on every screen. |
| Add to Library | Adds photos and videos to Photos, music to Music. |
| Alias | Makes a Finder alias. |
| Checksum | Copies the SHA-256 of the files. |
| Base64 | Copies the file as a data URI. |
| Markdown Link | Copies `[name](file:///…)` links. |
| Shortcut | Runs one of your Shortcuts with the files as input. |
| Script | Runs one of your shell scripts (Settings ▸ Send) with the files as `"$@"`. |

Show or hide the Basket at any time from the menu bar icon.

## 6. Where results are saved

By default the new file is saved next to the original with a descriptive name, such as `photo.png` or
`clip (trimmed).mp4`. Existing files are never overwritten and originals are never changed.

**Settings ▸ Output ▸ Save results** offers:

- **Next to the original** (default)
- **Downloads**
- **A folder I choose**
- **Ask every time**

If the original's folder is read-only, results go to Downloads. Turn on **Show results in Finder when done**
to have Finder reveal each result automatically.

## 7. Audio, video and iWork support

Images, PDFs, documents, spreadsheets, data, subtitles, archives and 3D models work right after installing.
A few formats need free software that Kumquat uses if it finds it:

| For | Install |
|---|---|
| Audio and video | [FFmpeg](https://ffmpeg.org): `brew install ffmpeg` |
| Saving WebP images, animated WebP | `brew install webp` |
| Saving JPEG XL | `brew install jpeg-xl` |
| Pictures to SVG | `brew install potrace` |
| LaTeX, reStructuredText, AsciiDoc, Org | `brew install pandoc` |
| Kindle e-books (MOBI, AZW3, FB2) | `brew install --cask calibre` |
| 7-Zip archives | `brew install sevenzip` |
| WOFF2 fonts | `brew install woff2` |
| TrueType ↔ OpenType outlines | `brew install fonttools` |
| Pages, Keynote, PowerPoint, Numbers, XLS | Pages, Keynote and Numbers from the Mac App Store |

The `brew` commands need [Homebrew](https://brew.sh). After installing, open **Settings ▸ Engines** and
click **Check Again**. Each line turns green when its program is found; **Copy Command** copies the install
command for anything missing.

## 8. Settings

Open it from the menu bar icon ▸ **Settings…** (or ⌘, while a Kumquat window is in front).

**General**

- **Open wheels while dragging files**: turn off to use only the keyboard shortcut and the menu.
- **Convert / Edit / Send wheel**: the key for each wheel. Choose ⇧, ⌘, ⌃, ⌥, or the number keys 1, 2, 3.
  Each wheel needs its own key. Number keys are useful when another app already reacts to modifier keys
  during a drag, and they need the Input Monitoring permission (see below).
- **Shortcut for the Finder selection**: click and press a new combination to replace ⌃⌥K.
- **Launch at login**, **Play sounds**.
- **Terminal action opens**: pick Terminal, iTerm, Warp or Ghostty, when more than one is installed.
- **Language**: English or Italiano, or **Same as the system** to follow macOS. Click **Restart Now** to
  switch straight away.
- **Updates**: **Check for updates automatically** (on by default), **Include beta versions**, and
  **Check Now**. See [section 10](#10-updating-and-uninstalling).

**Output**: where results go (section 6).

**Send**: favourite folders for Copy To and Move, and the shell scripts the Script action offers. Each
script runs in zsh with the files as `"$@"` (also one per line in `$KUMQUAT_FILES`).

**Engines**: which optional programs are installed (section 7).

**About**: version and licence.

## 9. Permissions

Kumquat asks only when a feature needs it.

| Permission | When | Where to change it |
|---|---|---|
| Automation ▸ Finder | First time you use the keyboard shortcut or the menu on a Finder selection | System Settings ▸ Privacy & Security ▸ Automation |
| Automation ▸ Pages, Keynote, Numbers | First conversion that uses one of them | same place |
| Input Monitoring | Only if a wheel is set to 1, 2 or 3 | System Settings ▸ Privacy & Security ▸ Input Monitoring |
| Speech Recognition | First transcription to SRT, VTT or TXT | System Settings ▸ Privacy & Security ▸ Speech Recognition |
| Photos | First Add to Library with photos or videos | System Settings ▸ Privacy & Security ▸ Photos |
| Local Network | First Wi-Fi Share | System Settings ▸ Privacy & Security ▸ Local Network |

Modifier keys (⇧ ⌘ ⌃ ⌥) need no permission. Kumquat does not ask for Accessibility access. It connects to the
internet only to look for updates on GitHub (section 10), never with your files; Wi-Fi Share only answers devices
on your own network that have its private link, while its window is open.

## 10. Updating and uninstalling

**Update**: Kumquat looks for a new version on GitHub once a day. When one is out it downloads it, checks
that it is signed with Kumquat's release key, and asks you: **Install and Relaunch** replaces the app and opens
the new version within seconds; **Later** keeps it ready under the menu bar icon ▸ **Install Kumquat x.y.z and
Relaunch**. To look straight away, choose **Check for Updates…** in the same menu. Your settings are kept.

- Nothing is installed unless its signature matches, and never a version older than yours. Kumquat never asks
  for your password to update.
- The daily check only asks GitHub for the list of releases: it sends nothing about you, your Mac or your files.
  Turn it off in Settings ▸ General ▸ Updates; **Check Now** there still works.
- **Include beta versions** also offers pre-releases, such as `1.2.0-beta.1`.
- If Kumquat can't replace itself where it is (it's running from the disk image, or the folder needs an
  administrator), it offers the download page instead. If macOS blocks it, allow Kumquat in System Settings ▸
  Privacy & Security ▸ App Management and choose **Check for Updates…** again. Or update by hand: quit Kumquat
  (menu bar icon ▸ **Quit Kumquat**), download the new DMG and drag Kumquat onto Applications again, choosing
  **Replace**.

If you use number keys, macOS may ask for Input Monitoring again after an update: remove Kumquat from that list
and add it back.

**Uninstall**

1. Quit Kumquat.
2. Move `/Applications/Kumquat.app` to the Bin.
3. Optionally delete its settings:

```bash
defaults delete app.kumquat.Kumquat
```

## 11. Troubleshooting

**"Kumquat can't be opened" or "Apple could not verify…"**
Follow [section 2](#2-first-launch). If macOS says the app is damaged, run the `xattr` command shown there.

**The wheel does not open while dragging**
- Check the menu bar icon ▸ **Open Wheels While Dragging** is ticked.
- Tap the key *after* you start dragging, not before.
- Another utility may claim the same key during drags. Switch the wheels to other keys in Settings ▸ General.

**Number keys do nothing**
Enable Kumquat in System Settings ▸ Privacy & Security ▸ Input Monitoring, then quit and reopen Kumquat.

**The keyboard shortcut does nothing**
Allow Kumquat to control Finder in System Settings ▸ Privacy & Security ▸ Automation.

**Video or audio options are dimmed**
FFmpeg is not installed. Run `brew install ffmpeg`, then Settings ▸ Engines ▸ **Check Again**.

**Translate or Summarize is dimmed**
Both need macOS 26. Translate also needs the language downloaded in System Settings ▸ General ▸ Language &
Region ▸ Translation Languages; Summarize needs Apple Intelligence turned on.

**A transcription finds no words**
Allow Kumquat in System Settings ▸ Privacy & Security ▸ Speech Recognition. Kumquat recognises the language
macOS is set to.

**A Pages, Keynote or Numbers conversion fails**
Install the app from the Mac App Store, open it once, and allow Kumquat to control it when asked.

**An update "isn't signed with Kumquat's release key" or "doesn't contain a valid copy of Kumquat"**
Kumquat refused a download that doesn't come from its maintainer, and installed nothing. Don't install that
version by hand: report it privately as [SECURITY.md](../SECURITY.md) explains.

**Still stuck?**
Open an [issue](https://github.com/organetto8/Kumquat/issues) with your macOS version, the file type and
the message shown in the progress card.
