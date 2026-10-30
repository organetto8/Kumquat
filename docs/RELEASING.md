# Releasing Kumquat

## Version numbers

Kumquat uses [Semantic Versioning](https://semver.org/), written in the `VERSION` file:

| Change | Example | When |
|---|---|---|
| Patch | 1.0.0 → 1.0.1 | Bug fixes only. Nothing new to learn. |
| Minor | 1.0.1 → 1.1.0 | New formats, tools, actions or settings. Existing behaviour and settings keep working. |
| Major | 1.4.2 → 2.0.0 | Something users rely on changes or goes away: a removed feature, settings reset, a higher minimum macOS. |

## Channels

- **Stable**: a normal GitHub release, marked *Latest*. The README's download link always points here.
- **Beta**: a GitHub *pre-release* with a hyphenated version, such as `1.1.0-beta.1`. Never marked Latest, so
  people only get it if they go looking for it. Announce it in Discussions and ask for feedback there.

Minor and major versions go through at least one beta. When a beta has run for a week with no serious bug,
the same code ships as the stable version. Patch releases can skip the beta.

**Hotfixes**: a crash, data loss or security problem in the latest stable release gets a patch release as
soon as it is fixed, without waiting for anything else on `main`.

Only the latest stable release is supported; there are no fixes for older lines.

## Branches

`main` is always releasable. Work happens on branches and lands through pull requests once CI (`make test`
and an app build) is green.

## Making a release

1. Check that CI is green on `main` and `git status` is clean.
2. In `CHANGELOG.md`, move the **Unreleased** entries under a new `## [x.y.z] - YYYY-MM-DD` heading and add its
   link at the bottom. For a beta, use `## [x.y.z-beta.n]`.
3. Write the version in `VERSION`.
4. Commit: `git commit -am "Kumquat x.y.z"`.
5. Build: `make release`. This makes the universal DMG, the ZIP and `SHA256SUMS.txt` in `build/`.
6. Smoke test the DMG on a Mac, ideally in a second user account that never ran Kumquat:
   install it, open it, drag a photo and convert it to PNG, open the Edit and Send wheels, look at
   Settings ▸ Engines, and check that **Copy Diagnostic Info** shows the new version.
7. Publish: `make publish`. It tags `vx.y.z`, pushes the commit and the tag, and creates the GitHub release
   with the files from `build/` and the notes from that version's `CHANGELOG.md` section. A hyphenated
   version becomes a pre-release; anything else becomes Latest.
8. If an issue is fixed in this release, comment there with the link and close it.

Releases are **immutable**: once published, their files and tag can't be changed or moved, so nobody can
swap a download later. A mistake in a published release is fixed with a new patch version.

## Engine pack

**Install** in Settings ▸ Engines downloads the optional programs from an `engines-N` release of this
repository, not from Homebrew. `Scripts/engines/build.sh` builds each one for Apple silicon and Intel, to run
on macOS 14 with nothing else installed (pandoc and Calibre are upstream's own builds and may need newer). The
**Engines** workflow runs it whenever `Scripts/engines/` changes, so a branch shows whether the builds still
work; its artifacts are the files a release would contain.

To publish a new pack, for example after raising a version in `build.sh`:

1. Check that the Engines workflow is green for the commit.
2. Tag it and push the tag: `git tag engines-2 && git push origin engines-2`. The workflow builds everything
   again and publishes the release with the archives, every source archive (`engines-2-sources.tar`) and
   `EnginePackManifest.swift`. It is never marked Latest, so the README's download link keeps pointing at
   the app.
3. Replace `Sources/KumquatCore/Support/EnginePackManifest.swift` with the copy attached to the release (the
   workflow summary shows it too) and commit it. Apps built from then on install from the new pack; older
   ones keep using the pack they were built with, which stays online because releases are immutable.

Never delete an engines release: published apps download from it. Downloads with an unpinned SHA-256 show
as notices in the workflow log; pin them in `build.sh` after a build you trust.

## Signing

Releases are signed ad hoc and not notarised, so the first launch needs **Open Anyway** in
System Settings ▸ Privacy & Security, as the README explains. With an Apple Developer ID, set
`SIGN_IDENTITY` and run `make notarize` after `make release` to remove that step.
