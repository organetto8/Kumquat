#!/bin/bash
# Builds one engine of Kumquat's engine pack for this Mac's processor, to run on macOS 14 and later:
#   dist/<engine>-<version>-<arch>.tar.xz   bin/ (and whatever else the engine needs) at the top
#   dist/<engine>-<arch>.json               what Scripts/engines/publish.py needs to know about it
#   dist/sources/                           the source archives behind it (left out on Intel)
# Run by .github/workflows/engines.yml on an Apple silicon and an Intel runner (docs/RELEASING.md).
#
#   Scripts/engines/build.sh ffmpeg|webp|jpeg-xl|potrace|pandoc|woff2|fonttools|sevenzip|calibre
set -euo pipefail

ENGINE=${1:?usage: build.sh <engine>}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
ARCH=$(uname -m)
WORK=$ROOT/.build/engines/$ENGINE-$ARCH
DIST=$ROOT/dist
PREFIX=$WORK/prefix
STAGE=$WORK/stage
JOBS=$(sysctl -n hw.ncpu)
HOST=$([[ $ARCH == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
MIN_MACOS=14.0
MINOS=$MIN_MACOS

export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS
# Libraries come only from $PREFIX, never from the runner's Homebrew: users don't have those.
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1

rm -rf "$WORK"
mkdir -p "$WORK/downloads" "$WORK/src" "$PREFIX/lib/pkgconfig" "$STAGE/bin" "$DIST/sources"

fail() { echo "::error title=$ENGINE ($ARCH)::$*" >&2; exit 1; }

# fetch <url> <file name> [sha256]: downloads into $WORK/downloads and prints the path. Without a pinned
# hash it reports the one it found, to pin after a first trusted build.
fetch() {
    local file=$WORK/downloads/$2 sum
    curl -fsSL --retry 3 -o "$file" "$1"
    sum=$(shasum -a 256 "$file" | cut -d' ' -f1)
    if [[ -z ${3:-} ]]; then
        echo "::notice title=Unpinned download::$2 $sum" >&2
    elif [[ $sum != "$3" ]]; then
        fail "$2 has SHA-256 $sum, expected $3"
    fi
    echo "$file"
}

# keep_source <file>: the licences of what the pack redistributes ask for its source next to it.
keep_source() { [[ $ARCH == x86_64 ]] || cp "$1" "$DIST/sources/"; }

# source_archive <url> <file name> [sha256]: fetches, keeps and unpacks a source archive into $WORK/src.
source_archive() {
    local file
    file=$(fetch "$@")
    keep_source "$file"
    tar -xf "$file" -C "$WORK/src"
}

# configure_make [options…], in an autotools source folder: a static library into $PREFIX.
configure_make() {
    ./configure --prefix="$PREFIX" --build="$HOST" --host="$HOST" --disable-shared --enable-static \
        --disable-dependency-tracking "$@"
    make -j"$JOBS"
    make install
}

# cmake_configure <source> [options…]: a static build in <source>/kumquat-build that finds only $PREFIX.
cmake_configure() {
    cmake -S "$1" -B "$1/kumquat-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DBUILD_SHARED_LIBS=OFF "${@:2}"
}

# cmake_install <source> [options…]: configures, builds and installs a static library into $PREFIX.
cmake_install() {
    cmake_configure "$@"
    cmake --build "$1/kumquat-build" -j "$JOBS"
    cmake --install "$1/kumquat-build"
}

# install_binary <file>…: copies programs into the pack, stripped and signed ad hoc (Apple silicon runs
# nothing unsigned, and strip invalidates the linker's signature), then checks them.
install_binary() {
    local file target
    for file in "$@"; do
        target=$STAGE/bin/$(basename "$file")
        cp "$file" "$target"
        strip "$target"
        codesign --force --sign - "$target"
        check_binary "$target"
    done
}

# minos_of <file>: the oldest macOS a Mach-O file runs on (the highest across its architectures).
minos_of() {
    otool -l "$1" | awk '$1 == "minos" { print $2 } /LC_VERSION_MIN_MACOSX/ { v = 1 } v && $1 == "version" { print $2; v = 0 }' |
        sort -V | tail -1
}

# note_minos <file>: raises the pack entry's minimum macOS to what <file> needs.
note_minos() {
    local minos
    minos=$(minos_of "$1")
    if [[ -n $minos ]]; then MINOS=$(printf '%s\n%s\n' "$MINOS" "$minos" | sort -V | tail -1); fi
}

# check_binary <file>: links only to macOS itself, so it runs on a Mac with nothing else installed.
check_binary() {
    local libraries
    libraries=$(otool -L "$1" | awk '/^\t/ { print $1 }' | grep -vE '^(/usr/lib/|/System/Library/)' || true)
    [[ -z $libraries ]] || fail "$(basename "$1") links to libraries outside macOS: $libraries"
    note_minos "$1"
}

# package <version> [arch]: dist/<engine>-<version>-<arch>.tar.xz from $STAGE, and its description.
package() {
    local version=$1 arch=${2:-$ARCH} file
    file=$ENGINE-$version-$arch.tar.xz
    tar -C "$STAGE" -cJf "$DIST/$file" .
    printf '{"engine": "%s", "version": "%s", "arch": "%s", "file": "%s", "minimumSystem": "%s"}\n' \
        "$ENGINE" "$version" "$arch" "$file" "$MINOS" >"$DIST/$ENGINE-$arch.json"
    echo "Packed $file: $(du -h "$DIST/$file" | cut -f1), macOS $MINOS or later"
}

# Small pictures and a font for the smoke tests, made from files every Mac has.
samples() {
    local icon=/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns
    sips -s format png -z 64 64 "$icon" --out "$WORK/sample.png" >/dev/null
    sips -s format jpeg "$WORK/sample.png" --out "$WORK/sample.jpg" >/dev/null
    sips -s format bmp "$WORK/sample.png" --out "$WORK/sample.bmp" >/dev/null
    cp "$(find /System/Library/Fonts -name '*.ttf' | head -1)" "$WORK/sample.ttf"
}

# MARK: - Engines

build_ffmpeg() {
    local version=8.1.3 x264=31e19f92f00c7003fa115047ce50978bc98c3a0d vpx=1.17.0 target list name
    command -v pkg-config >/dev/null || brew install pkgconf
    [[ $ARCH == arm64 ]] || brew install nasm

    source_archive "https://github.com/mirror/x264/archive/$x264.tar.gz" "x264-$x264.tar.gz"
    (cd "$WORK/src/x264-$x264" && ./configure --prefix="$PREFIX" --host="$HOST" --enable-static --enable-pic \
        --disable-cli --disable-opencl && make -j"$JOBS" && make install)

    source_archive https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz lame-3.100.tar.gz \
        ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
    (cd "$WORK/src/lame-3.100" && sed -i '' '/lame_init_old/d' include/libmp3lame.sym && configure_make --disable-frontend)

    source_archive https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.gz libogg-1.3.6.tar.gz
    (cd "$WORK/src/libogg-1.3.6" && configure_make)

    source_archive https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz libvorbis-1.3.7.tar.gz
    # The darwin flags libvorbis adds are refused by today's clang.
    (cd "$WORK/src/libvorbis-1.3.7" && sed -i '' 's/ -force_cpusubtype_ALL//g' configure &&
        configure_make --with-ogg="$PREFIX" --disable-examples)

    source_archive https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz opus-1.6.1.tar.gz
    (cd "$WORK/src/opus-1.6.1" && configure_make --disable-doc --disable-extra-programs)

    source_archive "https://github.com/webmproject/libvpx/archive/refs/tags/v$vpx.tar.gz" "libvpx-$vpx.tar.gz"
    target=$([[ $ARCH == arm64 ]] && echo arm64-darwin23-gcc || echo x86_64-darwin23-gcc)
    (cd "$WORK/src/libvpx-$vpx" && ./configure --prefix="$PREFIX" --target="$target" --disable-shared --enable-static \
        --enable-pic --enable-vp9-highbitdepth --disable-examples --disable-tools --disable-docs --disable-unit-tests &&
        make -j"$JOBS" && make install)

    source_archive "https://ffmpeg.org/releases/ffmpeg-$version.tar.xz" "ffmpeg-$version.tar.xz"
    # GPL for cropdetect and boxblur, which Kumquat uses; only macOS's own libraries are detected.
    (cd "$WORK/src/ffmpeg-$version" && ./configure --prefix="$PREFIX" --pkg-config-flags=--static \
        --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" --extra-libs=-liconv \
        --disable-autodetect --enable-gpl --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-bzlib \
        --enable-iconv --enable-libx264 --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libvpx \
        --disable-ffplay --disable-doc --disable-debug &&
        make -j"$JOBS")
    install_binary "$WORK/src/ffmpeg-$version/ffmpeg" "$WORK/src/ffmpeg-$version/ffprobe"

    # Captured first: grep -q would stop reading early and pipefail would count FFmpeg's broken pipe.
    list=$("$STAGE/bin/ffmpeg" -hide_banner -encoders)
    for name in h264_videotoolbox hevc_videotoolbox aac_at libx264 libmp3lame libopus libvorbis libvpx-vp9; do
        grep -qw -- "$name" <<<"$list" || fail "FFmpeg has no $name encoder"
    done
    list=$("$STAGE/bin/ffmpeg" -hide_banner -filters)
    for name in cropdetect boxblur; do
        grep -qw -- "$name" <<<"$list" || fail "FFmpeg has no $name filter"
    done
    "$STAGE/bin/ffmpeg" -hide_banner -loglevel error -f lavfi -i testsrc=duration=1:size=320x240:rate=10 \
        -f lavfi -i sine=duration=1 -c:v libx264 -c:a libmp3lame "$WORK/smoke.mp4"
    "$STAGE/bin/ffprobe" -hide_banner -loglevel error -show_format "$WORK/smoke.mp4" >/dev/null
    package "$version"
}

build_webp() {
    local version=1.6.0 png=1.6.59 jpeg=3.2.1 src
    [[ $ARCH == arm64 ]] || brew install nasm
    # cwebp reads PNG and JPEG through these; TIFF reaches it already converted to PNG.
    source_archive "https://github.com/pnggroup/libpng/archive/refs/tags/v$png.tar.gz" "libpng-$png.tar.gz"
    cmake_install "$WORK/src/libpng-$png" -DPNG_SHARED=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF
    source_archive "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/$jpeg.tar.gz" "libjpeg-turbo-$jpeg.tar.gz"
    cmake_install "$WORK/src/libjpeg-turbo-$jpeg" -DENABLE_SHARED=OFF -DWITH_TURBOJPEG=OFF

    source_archive "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$version.tar.gz" \
        "libwebp-$version.tar.gz" e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
    src=$WORK/src/libwebp-$version
    cmake_configure "$src" -DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_IMG2WEBP=ON -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_FUZZTEST=OFF
    cmake --build "$src/kumquat-build" -j "$JOBS"
    install_binary "$src/kumquat-build/cwebp" "$src/kumquat-build/img2webp"

    samples
    "$STAGE/bin/cwebp" -quiet "$WORK/sample.png" -o "$WORK/png.webp"
    "$STAGE/bin/cwebp" -quiet "$WORK/sample.jpg" -o "$WORK/jpg.webp"
    "$STAGE/bin/img2webp" -lossy "$WORK/sample.png" "$WORK/sample.png" -o "$WORK/anim.webp" >/dev/null
    package "$version"
}

build_jpeg_xl() {
    local version=0.12.0 commit=a7a9c787341cf703dede03c2009fa460cae5e5df src=$WORK/src/libjxl
    git clone --quiet --depth 1 --branch "v$version" https://github.com/libjxl/libjxl.git "$src"
    [[ $(git -C "$src" rev-parse HEAD) == "$commit" ]] || fail "libjxl v$version is not commit $commit"
    git -C "$src" submodule update --quiet --init --depth 1 third_party/brotli third_party/highway third_party/skcms \
        third_party/libpng third_party/zlib third_party/libjpeg-turbo
    [[ $ARCH == x86_64 ]] || tar -czf "$DIST/sources/libjxl-$version.tar.gz" --exclude .git -C "$WORK/src" libjxl
    cmake_configure "$src" -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TOOLS=ON -DJPEGXL_ENABLE_DOXYGEN=OFF \
        -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF \
        -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_VIEWERS=OFF \
        -DJPEGXL_ENABLE_DEVTOOLS=OFF -DJPEGXL_BUNDLE_LIBPNG=ON -DJPEGXL_ENABLE_SKCMS=ON \
        -DJPEGXL_FORCE_SYSTEM_BROTLI=OFF -DJPEGXL_FORCE_SYSTEM_HWY=OFF -DJPEGXL_FORCE_SYSTEM_LCMS2=OFF
    cmake --build "$src/kumquat-build" -j "$JOBS" --target cjxl
    install_binary "$src/kumquat-build/tools/cjxl"

    samples
    "$STAGE/bin/cjxl" "$WORK/sample.png" "$WORK/png.jxl" --quiet
    "$STAGE/bin/cjxl" "$WORK/sample.jpg" "$WORK/jpg.jxl" --quiet
    package "$version"
}

build_potrace() {
    local version=1.16
    source_archive "https://downloads.sourceforge.net/project/potrace/$version/potrace-$version.tar.gz" \
        "potrace-$version.tar.gz" be8248a17dedd6ccbaab2fcc45835bb0502d062e40fbded3bc56028ce5eb7acc
    (cd "$WORK/src/potrace-$version" && configure_make)
    install_binary "$PREFIX/bin/potrace"

    samples
    "$STAGE/bin/potrace" -s "$WORK/sample.bmp" -o "$WORK/sample.svg"
    package "$version"
}

# Upstream's own build, which is signed and kept as it is. It may need a newer macOS than 14: the app
# reads that from the pack and offers it only where it runs.
build_pandoc() {
    local version=3.13 zip sum
    case $ARCH in
        arm64) sum=f436d18bebbfb3ddd326597686dacab9fac5dc23bd060495020f35a28a43a7c3 ;;
        x86_64) sum=1823278715aa405aaf21b59cde5dc789346aa8d4fc307467f9a9ee84162bedc5 ;;
    esac
    zip=$(fetch "https://github.com/jgm/pandoc/releases/download/$version/pandoc-$version-$ARCH-macOS.zip" \
        "pandoc-$version-$ARCH-macOS.zip" "$sum")
    unzip -q "$zip" -d "$WORK/src"
    cp "$WORK/src/pandoc-$version-$ARCH/bin/pandoc" "$STAGE/bin/"
    check_binary "$STAGE/bin/pandoc"
    keep_source "$(fetch "https://github.com/jgm/pandoc/archive/refs/tags/$version.tar.gz" "pandoc-$version.tar.gz")"

    "$STAGE/bin/pandoc" --version | sed -n 1p
    package "$version"
}

build_woff2() {
    local version=1.0.2 brotli=1.2.1 src
    source_archive "https://github.com/google/brotli/archive/refs/tags/v$brotli.tar.gz" "brotli-$brotli.tar.gz"
    cmake_install "$WORK/src/brotli-$brotli" -DBROTLI_DISABLE_TESTS=ON
    source_archive "https://github.com/google/woff2/archive/refs/tags/v$version.tar.gz" "woff2-$version.tar.gz"
    src=$WORK/src/woff2-$version
    # The static Brotli decoder and encoder need the common part too, which woff2's CMake leaves out.
    cmake_configure "$src" -DCMAKE_EXE_LINKER_FLAGS="-L$PREFIX/lib -lbrotlicommon"
    cmake --build "$src/kumquat-build" -j "$JOBS"
    install_binary "$src/kumquat-build/woff2_compress" "$src/kumquat-build/woff2_decompress"

    samples
    "$STAGE/bin/woff2_compress" "$WORK/sample.ttf" >/dev/null
    "$STAGE/bin/woff2_decompress" "$WORK/sample.woff2" >/dev/null
    package "$version"
}

# fontTools on a self-contained Python. bin/fonttools finds that Python next to it, wherever the pack is.
build_fonttools() {
    local version=4.68.0 python=3.13.18 build=20261026 triple sum archive
    case $ARCH in
        arm64) triple=aarch64-apple-darwin sum=8392b6ea51d94391befb2c31ebe75463f045d0b69dfcf5e1bb3234e1f5fa3405 ;;
        x86_64) triple=x86_64-apple-darwin sum=7412c19d896c99431b74a18a5643e110449a7f9590fbab179c3e5ab27b9aa9e3 ;;
    esac
    archive=$(fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$build/cpython-$python+$build-$triple-install_only_stripped.tar.gz" \
        "cpython-$python-$triple.tar.gz" "$sum")
    tar -xf "$archive" -C "$STAGE"
    cat >"$WORK/requirements.txt" <<EOF
fonttools==$version \\
    --hash=sha256:f15de48b82a816c72f358e772792801bd3788a156caa76e1806cb0aa8148cd61 \\
    --hash=sha256:86d319a1feedfc75c8ff582d947b21fa1854e2829cb8cf9428784d750a05f1d9
EOF
    "$STAGE/python/bin/python3" -m pip install --quiet --disable-pip-version-check --no-deps --only-binary :all: \
        --require-hashes -r "$WORK/requirements.txt"
    # What Kumquat never runs: pip and the scripts it wrote (they name this runner's paths), Tk, tests.
    "$STAGE/python/bin/python3" -m pip uninstall --quiet --yes pip
    rm -rf "$STAGE"/python/bin/{fonttools,pyftmerge,pyftsubset,ttx,idle3*,pydoc3*} "$STAGE"/python/lib/{tcl,tk}* \
        "$STAGE"/python/lib/python3.*/{test,idlelib,tkinter,turtledemo,ensurepip}
    cat >"$STAGE/bin/fonttools" <<'EOF'
#!/bin/sh
# fontTools on the Python unpacked beside this folder (Kumquat's engine pack).
exec "$(dirname "$0")/../python/bin/python3" -I -m fontTools "$@"
EOF
    chmod +x "$STAGE/bin/fonttools"
    note_minos "$STAGE/python/bin/python3"

    samples
    "$STAGE/python/bin/python3" -I -c 'import sys; from fontTools.ttLib import TTFont; TTFont(sys.argv[1])' "$WORK/sample.ttf"
    "$STAGE/bin/fonttools" ttx -q -o "$WORK/sample.ttx" "$WORK/sample.ttf"
    package "$version"
}

# Upstream's universal build: one archive for both processors.
build_sevenzip() {
    local version=26.05 compact=2605 archive
    archive=$(fetch "https://github.com/ip7z/7zip/releases/download/$version/7z$compact-mac.tar.xz" "7z$compact-mac.tar.xz" \
        12ef6830317743cfd3f0ab1724bde43fcc270d8b6d8564f8c12c2a2b7f993570)
    tar -xf "$archive" -C "$STAGE/bin" 7zz
    check_binary "$STAGE/bin/7zz"
    keep_source "$(fetch "https://github.com/ip7z/7zip/releases/download/$version/7z$compact-src.tar.xz" "7z$compact-src.tar.xz" \
        0b6080b8c3e7a579161d2d495224c0e51c467576cb4c7048b0ab485ef44cc22e)"

    "$STAGE/bin/7zz" i >/dev/null
    package "$version" universal
}

# Upstream's universal, signed and notarised app, unchanged: Kumquat runs its ebook-convert.
build_calibre() {
    local version=9.17.0 dmg mount=$WORK/mount
    dmg=$(fetch "https://github.com/kovidgoyal/calibre/releases/download/v$version/calibre-$version.dmg" "calibre-$version.dmg")
    mkdir -p "$mount"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
    ditto "$mount/calibre.app" "$STAGE/calibre.app"
    hdiutil detach -quiet "$mount"
    rmdir "$STAGE/bin"
    codesign --verify --deep --strict "$STAGE/calibre.app" || fail "calibre.app's signature doesn't verify"
    note_minos "$STAGE/calibre.app/Contents/MacOS/calibre"
    note_minos "$STAGE/calibre.app/Contents/MacOS/ebook-convert"
    keep_source "$(fetch "https://github.com/kovidgoyal/calibre/releases/download/v$version/calibre-$version.tar.xz" "calibre-$version.tar.xz")"

    "$STAGE/calibre.app/Contents/MacOS/ebook-convert" --version | sed -n 1p
    package "$version" universal
}

case $ENGINE in
    ffmpeg | webp | potrace | pandoc | woff2 | fonttools | sevenzip | calibre) "build_$ENGINE" ;;
    jpeg-xl) build_jpeg_xl ;;
    *) fail "unknown engine $ENGINE" ;;
esac
