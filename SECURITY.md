# Security policy

## Supported versions

Only the latest stable release gets fixes. Pre-releases (betas) are for testing.

## Reporting a vulnerability

Don't open a public issue. Use **[Report a vulnerability](https://github.com/organetto8/Kumquat/security/advisories/new)**
on the Security tab, which only the maintainer can read.

- You get a first reply within 7 days.
- Once a fix is ready it ships as a patch release, and the advisory is published, crediting you if you wish.

## What's in scope

Kumquat makes no internet requests. Wi-Fi Share serves the files you chose to devices on your local
network that have its private link (a random token in the QR code), and only while its window is open.
Reports are especially welcome about:

- a crafted file that makes Kumquat, or an engine it launches, run code or write outside the chosen folder;
- Wi-Fi Share serving anything without the token or beyond the chosen files, or staying reachable after its window closes;
- the Script, Terminal or Shortcut actions running something the user did not choose.

Bugs in the optional tools themselves (FFmpeg, pandoc, Calibre and others) belong to their own projects.
