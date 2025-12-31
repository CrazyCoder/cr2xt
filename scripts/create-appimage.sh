#!/bin/bash
set -e

APP=cr2xt
ARCH=x86_64

ROOT="$PWD"
SRC="$ROOT/src"
BUILD="$ROOT/build"
APPDIR="$ROOT/AppDir"
FONTS_DIR="$ROOT/fonts"

# Qt version to use (via aqtinstall)
QT_VERSION="${QT_VERSION:-6.11.0}"
QT_ARCH="linux_gcc_64"  # Architecture for aqtinstall query
QT_DIR="$ROOT/Qt/$QT_VERSION/gcc_64"  # Actual install directory (aqtinstall always uses gcc_64)

# Parse arguments
CLEAN_BUILD=0
CLEAN_SRC=0
CLEAN_APPDIR=0
SKIP_BUILD=0
JOBS=$(nproc)

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --clean         Clean build (remove build, AppDir before building, keeps src)"
    echo "  --clean-src     Also remove src directory (triggers fresh git clone)"
    echo "  --clean-appdir  Only remove AppDir (keeps build, useful for re-packaging)"
    echo "  --skip-build    Skip build step, only create AppImage from existing build"
    echo "  -j N            Number of parallel jobs (default: $(nproc))"
    echo "  --qt VERSION    Qt version to use (default: $QT_VERSION)"
    echo "  -h, --help      Show this help"
    echo ""
    echo "Environment variables:"
    echo "  QT_VERSION    Qt version to install/use (default: 6.11.0)"
}

# Get version from CMakeLists.txt + git hash (same format as macOS/Windows scripts)
get_version() {
    local cmake_file="$SRC/CMakeLists.txt"
    if [ ! -f "$cmake_file" ]; then
        echo "0.0.0-unknown"
        return
    fi

    local major=$(grep -oP 'set\(CR2XT_VERSION_MAJOR\s+\K\d+' "$cmake_file" || echo "0")
    local minor=$(grep -oP 'set\(CR2XT_VERSION_MINOR\s+\K\d+' "$cmake_file" || echo "0")
    local patch=$(grep -oP 'set\(CR2XT_VERSION_PATCH\s+\K\d+' "$cmake_file" || echo "0")

    local git_hash=""
    if [ -d "$SRC/.git" ]; then
        git_hash=$(cd "$SRC" && git rev-parse --short HEAD 2>/dev/null || echo "")
    fi

    if [ -n "$git_hash" ]; then
        echo "${major}.${minor}.${patch}-${git_hash}"
    else
        echo "${major}.${minor}.${patch}"
    fi
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --clean)
            CLEAN_BUILD=1
            shift
            ;;
        --clean-src)
            CLEAN_SRC=1
            shift
            ;;
        --clean-appdir)
            CLEAN_APPDIR=1
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        -j)
            JOBS="$2"
            shift 2
            ;;
        --qt)
            QT_VERSION="$2"
            QT_DIR="$ROOT/Qt/$QT_VERSION/gcc_64"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

echo "=== cr2xt AppImage Builder ==="
echo "Qt version: $QT_VERSION"
echo "Jobs: $JOBS"
echo "Clean build: $CLEAN_BUILD"
echo "Clean src: $CLEAN_SRC"
echo "Clean AppDir: $CLEAN_APPDIR"
echo ""

# Ensure ~/.local/bin is in PATH for aqt
export PATH="$HOME/.local/bin:$PATH"

# Step 0 - Install Qt via aqtinstall if not present
if [ ! -d "$QT_DIR" ]; then
    echo "=== Installing Qt $QT_VERSION via aqtinstall ==="

    # Install aqtinstall if not present
    if ! command -v aqt &> /dev/null; then
        echo "Installing aqtinstall..."
        pip3 install --user aqtinstall
    fi

    mkdir -p "$ROOT/Qt"
    aqt install-qt linux desktop "$QT_VERSION" "$QT_ARCH" -O "$ROOT/Qt"

    if [ ! -d "$QT_DIR" ]; then
        echo "ERROR: Qt installation failed - $QT_DIR not found"
        exit 1
    fi
    echo "Qt $QT_VERSION installed to $QT_DIR"
fi

# Set Qt environment
export Qt6_DIR="$QT_DIR/lib/cmake/Qt6"
export PATH="$QT_DIR/bin:$PATH"
export LD_LIBRARY_PATH="$QT_DIR/lib:$LD_LIBRARY_PATH"
export QMAKE="$QT_DIR/bin/qmake"

echo "Using Qt from: $QT_DIR"
echo "qmake: $(which qmake)"

# Download linuxdeploy and Qt plugin (only if missing)
if [ ! -f "linuxdeploy-x86_64.AppImage" ]; then
    echo "=== Downloading linuxdeploy ==="
    wget https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
    chmod +x linuxdeploy-x86_64.AppImage
fi

if [ ! -f "linuxdeploy-plugin-qt-x86_64.AppImage" ]; then
    echo "=== Downloading linuxdeploy-plugin-qt ==="
    wget https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
    chmod +x linuxdeploy-plugin-qt-x86_64.AppImage
fi

# Clean if requested
if [ "$CLEAN_BUILD" -eq 1 ]; then
    echo "=== Cleaning previous build ==="
    rm -rf "$BUILD" "$APPDIR"
fi

# Clean AppDir only if requested (useful for re-packaging without rebuilding)
if [ "$CLEAN_APPDIR" -eq 1 ]; then
    echo "=== Cleaning AppDir ==="
    rm -rf "$APPDIR"
fi

# Clean src if requested (separate from build clean to avoid long re-clone)
if [ "$CLEAN_SRC" -eq 1 ]; then
    echo "=== Cleaning src directory ==="
    rm -rf "$SRC"
fi

# Ensure directories exist
mkdir -p "$BUILD" "$APPDIR"

if [ "$SKIP_BUILD" -eq 0 ]; then
    # Step 1 - Get sources (only if not present)
    if [ ! -d "$SRC/.git" ]; then
        echo "=== Cloning sources ==="
        rm -rf "$SRC"
        git clone --recursive https://github.com/CrazyCoder/cr2xt.git "$SRC"
    else
        echo "=== Sources already present, updating ==="
        cd "$SRC"
        # Reset any local changes to get clean copies
        git fetch origin
        git reset --hard origin/main
        git submodule foreach --recursive git reset --hard
        git submodule update --init --recursive --force
        cd "$ROOT"
    fi

    # Step 2 - Configure (only if not configured or clean build)
    if [ ! -f "$BUILD/CMakeCache.txt" ] || [ "$CLEAN_BUILD" -eq 1 ]; then
        echo "=== Configuring build ==="
        cmake -B "$BUILD" -S "$SRC" \
          -DCMAKE_PREFIX_PATH="$QT_DIR" \
          -DCMAKE_INSTALL_PREFIX=/usr \
          -DCMAKE_BUILD_TYPE=Release \
          -DUSE_QT=QT6 \
          -DUSE_COLOR_BACKBUFFER=OFF \
          -DGRAY_BACKBUFFER_BITS=2 \
          -DCRE_BUILD_SHARED=ON \
          -DCRE_BUILD_STATIC=OFF
    fi

    # Step 3 - Build
    echo "=== Building with $JOBS jobs ==="
    cmake --build "$BUILD" -j "$JOBS"
fi

# Get version for artifact naming
VERSION=$(get_version)
echo "Version: $VERSION"

# Step 4 - Install to AppDir
echo "=== Installing to AppDir ==="
rm -rf "$APPDIR"
mkdir -p "$APPDIR"
make -C "$BUILD" DESTDIR="$APPDIR" install

# Step 4b - Clean up development files not needed in AppImage
# CMake/GNUInstallDirs installs to lib/x86_64-linux-gnu/ on Debian/Ubuntu,
# but linuxdeploy copies libraries to lib/ - remove duplicates and dev files
echo "=== Cleaning up development files ==="

# Remove include directory (headers are not needed at runtime)
if [ -d "$APPDIR/usr/include" ]; then
    rm -rf "$APPDIR/usr/include"
    echo "  Removed: include/"
fi

LIBDIR_ARCH="$APPDIR/usr/lib/x86_64-linux-gnu"
if [ -d "$LIBDIR_ARCH" ]; then
    # Remove cmake and pkgconfig directories (not needed at runtime)
    rm -rf "$LIBDIR_ARCH/cmake" "$LIBDIR_ARCH/pkgconfig"
    echo "  Removed: cmake/, pkgconfig/"

    # Move libraries to /usr/lib/ and remove the arch-specific directory
    # (linuxdeploy will copy them there anyway, avoiding duplicates)
    for lib in "$LIBDIR_ARCH"/*.so*; do
        if [ -f "$lib" ] || [ -L "$lib" ]; then
            libname=$(basename "$lib")
            # Skip development symlinks (*.so without version) - not needed at runtime
            if [[ "$libname" =~ \.so$ ]] && [ -L "$lib" ]; then
                rm "$lib"
                echo "  Removed (dev symlink): $libname"
            else
                mv "$lib" "$APPDIR/usr/lib/"
                echo "  Moved: $libname"
            fi
        fi
    done
    rmdir "$LIBDIR_ARCH" 2>/dev/null || true
fi

# Symlink to cr2xt
ln -sf crqt "$APPDIR/usr/bin/cr2xt"

# Step 5 - Copy fonts (same patterns as Windows/macOS builds)
echo "=== Copying fonts ==="
FONTS_DEST="$APPDIR/usr/share/crengine-ng/fonts"
mkdir -p "$FONTS_DEST"

if [ -d "$FONTS_DIR" ]; then
    # Copy fonts matching patterns from dist-config
    for pattern in "NotoSans-*.ttf" "Roboto*.ttf" "TerminusTTFWindows-*.ttf"; do
        for font in "$FONTS_DIR"/$pattern; do
            if [ -f "$font" ]; then
                cp "$font" "$FONTS_DEST/"
                echo "  Copied: $(basename "$font")"
            fi
        done
    done
    echo "Fonts copied to $FONTS_DEST"
else
    echo "WARNING: Fonts directory not found at $FONTS_DIR"
    echo "         Place fonts in $FONTS_DIR or they won't be included"
fi

# Step 5b - Copy crqt resources (backgrounds, textures, i18n) to crengine-ng directory
# On Linux AppImage, getMainDataDir() returns crengine-ng dir, so all resources must be there
echo "=== Copying crqt resources to crengine-ng ==="
CRENGINE_DATA="$APPDIR/usr/share/crengine-ng"
CRQT_DATA="$APPDIR/usr/share/crqt"

if [ -d "$CRQT_DATA/backgrounds" ]; then
    cp -r "$CRQT_DATA/backgrounds" "$CRENGINE_DATA/"
    echo "  Copied: backgrounds/"
fi
if [ -d "$CRQT_DATA/textures" ]; then
    cp -r "$CRQT_DATA/textures" "$CRENGINE_DATA/"
    echo "  Copied: textures/"
fi
if [ -d "$CRQT_DATA/i18n" ]; then
    cp -r "$CRQT_DATA/i18n" "$CRENGINE_DATA/"
    echo "  Copied: i18n/"
fi

# Step 6 - AppImage metadata
echo "=== Setting up AppImage metadata ==="

# Desktop file
install -Dm644 \
  "$SRC/crqt-ng/src/desktop/crqt.desktop" \
  "$APPDIR/cr2xt.desktop"

# Replace crqt with cr2xt in desktop-file
sed -i 's|Exec=crqt|Exec=cr2xt|g' "$APPDIR/cr2xt.desktop"

# Icon
install -Dm644 \
  "$SRC/crqt-ng/src/desktop/crqt.png" \
  "$APPDIR/cr2xt.png"

# AppRun - set environment variables so crengine finds its data files
cat > "$ROOT/custom-apprun" << 'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
export LD_LIBRARY_PATH="$HERE/usr/lib:$HERE/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="$HERE/usr/plugins"
export QT_QPA_PLATFORM_PLUGIN_PATH="$HERE/usr/plugins/platforms"
# Use xcb (X11) platform by default to avoid wayland plugin warnings
# User can override with QT_QPA_PLATFORM=wayland if needed
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
# Set data paths so crengine finds CSS, fonts, hyph patterns, etc.
export XDG_DATA_DIRS="$HERE/usr/share:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
exec "$HERE/usr/bin/cr2xt" "$@"
EOF
chmod +x "$ROOT/custom-apprun"

# Step 7 - Create AppImage with linuxdeploy (without final output yet)
echo "=== Running linuxdeploy ==="
export PATH="$PWD:$PATH"
export DISABLE_COPYRIGHT_FILES_DEPLOYMENT=1
export LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu:$LD_LIBRARY_PATH"

# Run linuxdeploy to bundle Qt and basic dependencies (no output yet)
# linuxdeploy will find and execute the Qt plugin AppImage directly via PATH
NO_STRIP=1 QMAKE="$QMAKE" ./linuxdeploy-x86_64.AppImage \
  --appdir "$APPDIR" \
  --desktop-file "$APPDIR/cr2xt.desktop" \
  --icon-file "$APPDIR/cr2xt.png" \
  --custom-apprun "$ROOT/custom-apprun" \
  --plugin qt

# Step 7b - Copy additional Qt plugins not bundled by linuxdeploy-plugin-qt
echo "=== Copying additional Qt plugins ==="
# Copy GTK3 theme plugin for native look on GTK-based desktops
if [ -f "$QT_DIR/plugins/platformthemes/libqgtk3.so" ]; then
    cp "$QT_DIR/plugins/platformthemes/libqgtk3.so" "$APPDIR/usr/plugins/platformthemes/"
    echo "  Copied: libqgtk3.so (GTK3 theme integration)"
fi

# Step 7c - Filter Qt translations to only include languages supported by crqt
# linuxdeploy-plugin-qt bundles ALL Qt translations, but we only need those matching crqt languages
# Supported languages: bg, cs, hu, nl, ru, uk (+ en which has no qt_en.qm usually)
echo "=== Filtering Qt translations ==="
QT_TRANS_DIR="$APPDIR/usr/translations"
if [ -d "$QT_TRANS_DIR" ]; then
    SUPPORTED_LANGS="en ru uk cs bg hu nl"
    removed_count=0
    kept_count=0

    for qm_file in "$QT_TRANS_DIR"/qt_*.qm "$QT_TRANS_DIR"/qtbase_*.qm; do
        [ -f "$qm_file" ] || continue
        filename=$(basename "$qm_file")

        # Extract language code from filename (e.g., qt_ru.qm -> ru, qtbase_cs.qm -> cs)
        lang_code=$(echo "$filename" | sed -E 's/^(qt|qtbase)_([a-z]+).*\.qm$/\2/')

        # Check if this language is supported
        keep=0
        for supported in $SUPPORTED_LANGS; do
            if [ "$lang_code" = "$supported" ]; then
                keep=1
                break
            fi
        done

        if [ "$keep" -eq 0 ]; then
            rm -f "$qm_file"
            ((removed_count++)) || true
        else
            ((kept_count++)) || true
        fi
    done

    echo "  Kept $kept_count Qt translation files for supported languages"
    echo "  Removed $removed_count Qt translation files for unsupported languages"
else
    echo "  No Qt translations directory found"
fi

# Step 8 - Bundle additional libraries that linuxdeploy excludes
echo "=== Bundling additional libraries ==="

# Libraries that should NOT be bundled (system/driver dependent)
# Read from excludelist file (AppImage standard format)
EXCLUDELIST_FILE="$ROOT/excludelist"
if [ -f "$EXCLUDELIST_FILE" ]; then
    # Read uncommented lines from excludelist file
    EXCLUDE_LIBS=$(grep -v "^#" "$EXCLUDELIST_FILE" | grep -v "^$" | tr "\n" " ")
else
    echo "WARNING: excludelist file not found at $EXCLUDELIST_FILE"
    EXCLUDE_LIBS=""
fi

# Function to check if a library should be excluded
should_exclude() {
    local lib="$1"
    for pattern in $EXCLUDE_LIBS; do
        if [[ "$lib" == *"$pattern"* ]]; then
            return 0  # true, should exclude
        fi
    done
    return 1  # false, should include
}

# Function to copy a library and its dependencies recursively
copy_lib_recursive() {
    local lib_path="$1"
    local dest_dir="$APPDIR/usr/lib"
    local lib_name=$(basename "$lib_path")

    # Skip if already copied or should be excluded
    if [ -f "$dest_dir/$lib_name" ] || should_exclude "$lib_name"; then
        return
    fi

    # Skip if source doesn't exist
    if [ ! -f "$lib_path" ]; then
        return
    fi

    echo "  Bundling: $lib_name"
    cp -L "$lib_path" "$dest_dir/"

    # Recursively copy dependencies
    local deps=$(ldd "$lib_path" 2>/dev/null | grep "=> /" | awk '{print $3}')
    for dep in $deps; do
        copy_lib_recursive "$dep"
    done
}

# Get all dependencies of main binaries and libraries in AppDir
echo "Scanning for missing dependencies..."
mkdir -p "$APPDIR/usr/lib"

# Collect all needed libraries
NEEDED_LIBS=$(
    find "$APPDIR/usr/bin" "$APPDIR/usr/lib" -type f \( -executable -o -name "*.so*" \) 2>/dev/null | \
    xargs -I{} ldd {} 2>/dev/null | \
    grep "=> /" | \
    awk '{print $3}' | \
    sort -u
)

# Copy missing libraries
EXCLUDED_LIST=""
for lib in $NEEDED_LIBS; do
    lib_name=$(basename "$lib")
    # Check if not already in AppDir and not excluded
    if [ -f "$APPDIR/usr/lib/$lib_name" ]; then
        continue  # Already copied
    elif should_exclude "$lib_name"; then
        EXCLUDED_LIST="$EXCLUDED_LIST $lib_name"
    else
        copy_lib_recursive "$lib"
    fi
done

# Report excluded libraries
if [ -n "$EXCLUDED_LIST" ]; then
    echo ""
    echo "Excluded system libraries:"
    for lib in $EXCLUDED_LIST; do
        echo "  - $lib"
    done | sort -u
fi

# Step 9 - Create final AppImage
echo "=== Creating final AppImage ==="
# Set output filename with version
export OUTPUT="cr2xt-${VERSION}-linux-${ARCH}.AppImage"

# Use appimagetool directly for final packaging (linuxdeploy already set up AppDir)
if [ ! -f "appimagetool-x86_64.AppImage" ]; then
    echo "Downloading appimagetool..."
    wget https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
    chmod +x appimagetool-x86_64.AppImage
fi

ARCH=x86_64 ./appimagetool-x86_64.AppImage "$APPDIR" "$OUTPUT"

# Find and report the created AppImage
if [ -f "$OUTPUT" ]; then
    echo ""
    echo "=== SUCCESS ==="
    echo "AppImage created: $PWD/$OUTPUT"
    ls -lh "$OUTPUT"
else
    # Try to find any cr2xt AppImage
    APPIMAGE=$(ls -1t cr2xt*.AppImage 2>/dev/null | head -1)
    if [ -n "$APPIMAGE" ]; then
        echo ""
        echo "=== SUCCESS ==="
        echo "AppImage created: $PWD/$APPIMAGE"
        ls -lh "$APPIMAGE"
    else
        echo "Warning: AppImage file not found"
    fi
fi
