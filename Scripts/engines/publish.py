#!/usr/bin/env python3
"""Turns the engine builds in dist/ into the extra files of an engines-N release: the release notes, one
archive with every source, and EnginePackManifest.swift, which pins the app to this release.

    Scripts/engines/publish.py engines-N dist

Run by .github/workflows/engines.yml after the builds; see docs/RELEASING.md."""

import hashlib
import json
import pathlib
import sys
import tarfile

LICENCES = {
    "calibre": "GPL 3.0 (upstream build)",
    "ffmpeg": "GPL 2.0 or later (FFmpeg, x264); LAME: LGPL 2.0; Opus, Vorbis, libvpx: BSD",
    "fonttools": "MIT (fontTools); Python: PSF",
    "jpeg-xl": "BSD (libjxl and the libraries it bundles)",
    "pandoc": "GPL 2.0 or later (upstream build)",
    "potrace": "GPL 2.0 or later",
    "sevenzip": "LGPL 2.1 with the unRAR restriction (upstream build)",
    "webp": "BSD (libwebp, libjpeg-turbo); libpng licence",
    "woff2": "MIT (woff2, Brotli)",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main(tag, dist):
    builds = sorted((json.loads(p.read_text()) for p in dist.glob("*.json")), key=lambda b: (b["engine"], b["arch"]))
    if not builds:
        sys.exit("no builds in " + str(dist))

    entries = []
    for build in builds:
        path = dist / build["file"]
        digest, size = sha256(path), path.stat().st_size
        for arch in ["arm64", "x86_64"] if build["arch"] == "universal" else [build["arch"]]:
            entries.append(f'        "{build["engine"]}-{arch}": Asset(file: "{build["file"]}", sha256: "{digest}", '
                           f'size: {size}, minimumSystem: "{build["minimumSystem"]}"),')
    (dist / "EnginePackManifest.swift").write_text(f"""\
// Which engines-N release the app installs engines from, and the SHA-256 of each file in it.
// Scripts/engines/publish.py attaches this file to every engines release: replace this copy with that
// one to move the app to a new pack (docs/RELEASING.md). Empty until the first engines release.
extension EnginePack {{
    static let release: String? = "{tag}"
    static let assets: [String: Asset] = [
{chr(10).join(sorted(entries))}
    ]
}}
""")

    sources = dist / f"{tag}-sources.tar"
    with tarfile.open(sources, "w") as archive:
        for path in sorted((dist / "sources").glob("*")):
            archive.add(path, arcname=f"{tag}-sources/{path.name}")

    rows = {}
    for build in builds:
        row = rows.setdefault(build["engine"], {"version": build["version"], "arches": [], "macos": build["minimumSystem"]})
        row["arches"].append({"arm64": "Apple silicon", "x86_64": "Intel", "universal": "Apple silicon, Intel"}[build["arch"]])
        row["macos"] = max(row["macos"], build["minimumSystem"], key=lambda v: tuple(int(p) for p in v.split(".")))
    table = "\n".join(f"| {engine} | {row['version']} | {', '.join(row['arches'])} | {row['macos']} | {LICENCES.get(engine, '')} |"
                      for engine, row in sorted(rows.items()))
    (dist / "NOTES.md").write_text(f"""\
The engines Kumquat installs from **Settings ▸ Engines ▸ Install**, for Macs without Homebrew. They are not
meant to be downloaded by hand: Kumquat picks the file for the Mac, checks it against the SHA-256 built into
the app and unpacks it into `~/Library/Application Support/Kumquat/Engines`.

| Engine | Version | Processors | macOS | Licence |
|---|---|---|---|---|
{table}

Built by `Scripts/engines/build.sh` from the source archives in **{sources.name}**; the scripts and build
logs are linked from the commit this release is tagged on. These are separate programs that Kumquat runs;
each keeps its own licence.
""")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], pathlib.Path(sys.argv[2]))
