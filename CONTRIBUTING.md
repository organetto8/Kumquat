# Contributing to Kumquat

Thanks for helping. Kumquat is a personal project maintained in spare time, so this page explains what to
expect and how to make a report or a change land quickly.

## What Kumquat is, and isn't

- Everything runs on the Mac. No uploads, no account, no telemetry, no update checks. Changes that add a
  network request are declined; Wi-Fi Share, which only talks to the local network, is the one exception.
- Apple frameworks first. Formats Apple can't handle use free command-line tools that the user installs,
  usually from Homebrew, and that Kumquat finds on its own. Nothing is bundled.
- English and Italian are both complete. New text the user sees needs both.

## Asking, reporting, requesting

| You want to… | Go to |
|---|---|
| Ask how to do something, or discuss an idea | [Discussions](https://github.com/organetto8/Kumquat/discussions) |
| Report a bug | [Bug report](https://github.com/organetto8/Kumquat/issues/new?template=bug_report.yml), with **Copy Diagnostic Info** from the menu bar |
| Ask for a format, tool or action | [Feature or format request](https://github.com/organetto8/Kumquat/issues/new?template=feature_request.yml) |
| Report a security problem | [Private report](https://github.com/organetto8/Kumquat/security/advisories/new), never a public issue ([policy](SECURITY.md)) |

Issues and pull requests are in English.

## How issues are handled

- **First reply within 7 days.** Usually sooner; holidays happen.
- **Labels** say where an issue stands:

  | Label | Meaning |
  |---|---|
  | `bug` / `enhancement` | Set by the form you used |
  | `format-request` | Asks for a new file format |
  | `needs-info` | Waiting for an answer or a sample file from the reporter |
  | `confirmed` | Reproduced, or accepted as a request |
  | `help wanted` / `good first issue` | Open for a pull request |
  | `duplicate` / `wontfix` | Closed with a link or a reason |

- **`needs-info`** comes off by itself when the reporter replies. With no reply for 14 days the issue is
  marked stale, and 7 days later it closes. A comment reopens the conversation at any time.
- **Confirmed bugs** go into the next patch release; crashes and data loss first.
- **Requests** are weighed by how many people need them (👍 on the issue), whether they fit the principles
  above, and whether a free local tool can do the job. A `wontfix` always comes with the reason.

## Pull requests

1. For anything bigger than a small fix, open an issue first, so we agree on the approach before you write it.
2. Branch from `main`. One topic per pull request.
3. Follow the build steps in the [README](README.md#build-from-source). `make test` must pass; CI runs it on
   every pull request.
4. New strings: run `make strings`, then add the Italian translation in `Resources/Localizable.xcstrings`.
5. Update `docs/USER_GUIDE.md` if behaviour changes, and add a line under **Unreleased** in `CHANGELOG.md`.
6. Write commit messages in English, in the imperative ("Add WebP to the Convert wheel").

By contributing you agree that your work is released under the project's [MIT licence](LICENSE), and that
you follow the [code of conduct](CODE_OF_CONDUCT.md).

## Releases

How versions are numbered and published is in [docs/RELEASING.md](docs/RELEASING.md).
