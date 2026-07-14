# Building cr2xt

cr2xt builds on Windows, Linux, and macOS. Requirements common to all platforms:

- Qt6 (Core, Gui, Widgets modules)
- CMake 3.16+
- C++17 compatible compiler
- crengine dependencies: freetype, harfbuzz, libpng, libjpeg-turbo, libwebp,
  fribidi, zstd, utf8proc, libunibreak (>= 4.0), fontconfig, zlib
- Optional: libjxl (JPEG XL image support — enabled automatically when found)

Clone with submodules:

```bash
git clone --recursive https://github.com/CrazyCoder/cr2xt.git
```

Common CMake options used for release builds:

| Option | Value | Purpose |
|--------|-------|---------|
| `-DUSE_QT=QT6` | required | Build against Qt6 |
| `-DUSE_COLOR_BACKBUFFER=OFF` | required | Grayscale rendering backbuffer |
| `-DGRAY_BACKBUFFER_BITS=2` | required | 2-bit grayscale (XTC/XTH export) |
| `-DWITH_LIBUNIBREAK=ON` | recommended | Fail configure if libunibreak is missing instead of silently degrading line breaking |
| `-DCRE_BUILD_SHARED=ON -DCRE_BUILD_STATIC=OFF` | recommended | Shared crengine-ng library |

> **Tip:** `.github/workflows/build.yml` builds all release artifacts on GitHub-hosted
> runners and is kept working — treat it as the executable reference for exact
> dependencies and flags on every platform.

## Windows (MSYS2 / MinGW64)

Install [MSYS2](https://www.msys2.org/), then from a MinGW64 shell:

```bash
pacman -S --needed \
    mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake mingw-w64-x86_64-ninja \
    mingw-w64-x86_64-ccache mingw-w64-x86_64-python \
    mingw-w64-x86_64-qt6-base mingw-w64-x86_64-qt6-tools \
    mingw-w64-x86_64-qt6-translations mingw-w64-x86_64-qt6-imageformats \
    mingw-w64-x86_64-freetype mingw-w64-x86_64-harfbuzz \
    mingw-w64-x86_64-libpng mingw-w64-x86_64-libjpeg-turbo \
    mingw-w64-x86_64-libwebp mingw-w64-x86_64-fribidi \
    mingw-w64-x86_64-zstd mingw-w64-x86_64-libutf8proc \
    mingw-w64-x86_64-libunibreak mingw-w64-x86_64-libjxl \
    mingw-w64-x86_64-fontconfig mingw-w64-x86_64-zlib
```

Build the portable distribution (from PowerShell; runs CMake inside MSYS2,
then windeployqt, DLL bundling, and zip/7z packaging):

```powershell
.\scripts\build-dist-windows.ps1 -Build -Msys2Root C:\msys64 -SourceDir $env:TEMP\cr2xt-install
```

Or configure and build manually from the MinGW64 shell
(`-DCON_DEBUG:BOOL=OFF` produces a GUI binary without a console window):

```bash
cmake -B build/release -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCON_DEBUG:BOOL=OFF \
    -DUSE_QT=QT6 \
    -DUSE_COLOR_BACKBUFFER=OFF \
    -DGRAY_BACKBUFFER_BITS=2 \
    -DWITH_LIBUNIBREAK=ON

cmake --build build/release --target all -j$(nproc)
cmake --build build/release --target install
```

## Linux

Install build dependencies (Ubuntu 22.04 package names):

```bash
sudo apt-get install -y \
    build-essential cmake ccache python3-pip wget file \
    libfreetype-dev libharfbuzz-dev libpng-dev libjpeg-turbo8-dev \
    libwebp-dev libfribidi-dev libzstd-dev libutf8proc-dev \
    libfontconfig1-dev zlib1g-dev libgl1-mesa-dev libxkbcommon-dev
```

**libunibreak:** crengine-ng requires libunibreak >= 4.0 for proper line
breaking. Ubuntu 22.04 only packages the ancient 1.1, so build it from source
(newer distributions may package a suitable version):

```bash
wget https://github.com/adah1972/libunibreak/releases/download/libunibreak_6_1/libunibreak-6.1.tar.gz
tar xzf libunibreak-6.1.tar.gz && cd libunibreak-6.1
./configure --prefix=/usr/local && make -j$(nproc) && sudo make install && sudo ldconfig
```

**Qt6** can come from distro packages (`qt6-base-dev qt6-tools-dev`) or from
the official Qt binaries via [aqtinstall](https://github.com/miurahr/aqtinstall)
(what the AppImage build uses).

### AppImage

`scripts/create-appimage.sh` handles everything: installs Qt via aqtinstall,
builds, and packages with linuxdeploy. Run it from an empty work directory.
The AppImage build additionally needs the Qt xcb runtime libraries
(`libxkbcommon-x11-0` and `libxcb-*`, see the `linux` job in
`.github/workflows/build.yml` for the full list) and `libfuse2` (or set
`APPIMAGE_EXTRACT_AND_RUN=1`).

```bash
mkdir -p ~/cr2xt-build && cd ~/cr2xt-build
/path/to/cr2xt/scripts/create-appimage.sh --src /path/to/cr2xt   # or omit --src to clone from GitHub
```

### Manual build

```bash
cmake -B build/release \
    -DCMAKE_BUILD_TYPE=Release \
    -DUSE_QT=QT6 \
    -DUSE_COLOR_BACKBUFFER=OFF \
    -DGRAY_BACKBUFFER_BITS=2 \
    -DWITH_LIBUNIBREAK=ON

cmake --build build/release -j$(nproc)
```

## macOS

Install dependencies via Homebrew:

```bash
brew install cmake ninja qt@6 freetype harfbuzz libpng jpeg-turbo webp \
    fribidi zstd utf8proc libunibreak jpeg-xl fontconfig dbus
```

For DMG creation, install one of:

```bash
pipx install dmgbuild     # headless-friendly, used by CI (brew install pipx first if needed)
brew install create-dmg   # alternative; needs a GUI session for the pretty layout
```

`scripts/build-dist-macos.sh` builds, bundles Qt (macdeployqt), ad-hoc signs,
and creates a DMG:

```bash
# Native architecture build + DMG
./scripts/build-dist-macos.sh --clean

# Build only (skip DMG)
./scripts/build-dist-macos.sh --clean --skip-dmg

# Set the minimum macOS version (defaults to scripts/dist-config-macos.json).
# Note: bundled Homebrew libraries only support the macOS version they were
# installed on, so the effective minimum is your host OS version.
./scripts/build-dist-macos.sh -m 15.0
```

### Universal binaries (x86_64 + arm64)

Homebrew prefixes are single-architecture, so a universal build needs two
per-architecture builds merged afterwards. Two ways to get there:

- **One Apple Silicon machine with dual Homebrew** (`/opt/homebrew` native +
  `/usr/local` under Rosetta): `./scripts/build-dist-macos.sh --universal`
  builds both architectures and merges them with `lipo`.
- **Two machines/CI runners** (how GitHub Actions does it): build each
  architecture with `-a arm64` / `-a x86_64 --skip-dmg`, copy both
  `dist/macos-<arch>/cr2xt.app` bundles to one machine, then merge:
  `./scripts/build-dist-macos.sh --merge-only`

## Release builds on GitHub Actions

`.github/workflows/build.yml` builds all platforms (Windows portable zip/7z,
Linux AppImage, macOS per-arch + universal DMGs) and can be dispatched manually
from the Actions tab. Pushing a `v*.*.*` tag runs
`.github/workflows/release.yml`, which uploads the artifacts to a draft GitHub
release. The workflow accepts runner-label inputs so forks can point jobs at
their own self-hosted runners; macOS release DMGs target macOS 15+.
