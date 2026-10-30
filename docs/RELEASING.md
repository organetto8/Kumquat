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
5. Build: `make release`. This makes the universal DMG, the ZIP, the ZIP's update signature
   (`Kumquat-x.y.z.zip.sig`) and `SHA256SUMS.txt` in `build/`. macOS may ask once to let `swift` use the
   signing key in the keychain.
6. Smoke test the DMG on a Mac, ideally in a second user account that never ran Kumquat:
   install it, open it, drag a photo and convert it to PNG, open the Edit and Send wheels, look at
   Settings ▸ Engines, and check that **Copy Diagnostic Info** shows the new version.
7. Publish: `make publish`. It tags `vx.y.z`, pushes the commit and the tag, and creates the GitHub release
   with the files from `build/` and the notes from that version's `CHANGELOG.md` section. A hyphenated
   version becomes a pre-release; anything else becomes Latest.
8. If an issue is fixed in this release, comment there with the link and close it.

Releases are **immutable**: once published, their files and tag can't be changed or moved, so nobody can
swap a download later. A mistake in a published release is fixed with a new patch version.

## Signing

Releases are signed ad hoc and not notarised, so the first launch needs **Open Anyway** in
System Settings ▸ Privacy & Security, as the README explains. With an Apple Developer ID, set
`SIGN_IDENTITY` and run `make notarize` after `make release` to remove that step.

## Update signing key

The in-app updater installs a release only if its ZIP comes with `Kumquat-x.y.z.zip.sig`: an Ed25519 signature,
made with the release key, of

```
kumquat-update-1
app.kumquat.Kumquat
x.y.z
<SHA-256 of Kumquat-x.y.z.zip, lowercase hex>
```

The app carries the public half in `Resources/Info.plist` (`KumquatUpdatePublicKey`). The private half lives
only in the maintainer's login keychain, so whoever takes over the GitHub account, the CI or the network still
can't ship an update. A build whose `KumquatUpdatePublicKey` is empty never looks for updates, and
`make publish` refuses to publish it.

**Once, before the first release with the updater**

1. `make update-key`. It creates the key in the login keychain (item *Kumquat update signing key*) and writes
   the public half into `Resources/Info.plist`.
2. Commit `Resources/Info.plist`.
3. Back the key up offline, for example in a password manager:
   `swift Scripts/update-signing.swift export` prints it. Never commit it, paste it in an issue or give it to CI.

**On another Mac**: `swift Scripts/update-signing.swift import`, then paste the backed-up key.

**If the key is lost**, copies already installed can't be updated automatically any more: run `make update-key`
again, release, and tell users in the release notes and Discussions to download that version by hand once.

**If the key leaks**, whoever holds it can sign an update; they would still need to publish it as a release of
this repository, since that is the only place the app downloads from, but don't wait for that. Rotate at once:

1. `swift Scripts/update-signing.swift rotate`: a new key goes into the keychain next to the current one, and its
   public half into `Resources/Info.plist`. Commit it.
2. Release a patch version as usual. It is signed with the current key, so installed copies accept it, and it
   carries the new public key, so from then on they trust only the new one.
3. `swift Scripts/update-signing.swift finish-rotation`: the new key becomes the signing key. Back it up.
4. Announce it as a security fix.

The first version with the updater has to be installed by hand by people on 1.0.0; after that, updates arrive
by themselves. Because releases are signed ad hoc, macOS treats each version as a new app for Input Monitoring,
as it does when updating by hand.
