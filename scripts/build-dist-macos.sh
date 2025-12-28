#!/bin/bash
#
# build-dist-macos.sh - Build a portable distribution of cr2xt for macOS
#
# This script packages the cr2xt application into a macOS app bundle
# and creates a DMG disk image for distribution.
#
# Usage:
#   ./build-dist-macos.sh [options]
#
# Options:
#   -c, --clean          Clean build directory before building
#   -b, --build          Run CMake build (default: true)
#   -s, --skip-deploy    Skip running macdeployqt
#   -d, --skip-dmg       Skip creating DMG
#   -j, --jobs N         Number of parallel build jobs (default: auto)
#   -u, --universal      Build Universal Binary (arm64 + x86_64)
#   -a, --arch ARCH      Target architecture(s) (default: native, or "arm64;x86_64" for universal)
#   -h, --help           Show this help message
#
# Environment variables:
#   DEVELOPER_ID         Code signing identity (optional)
#   APPLE_ID             Apple ID for notarization (optional)
#   APP_PASSWORD         App-specific password for notarization (optional)
#   TEAM_ID              Team ID for notarization (optional)

set -euo pipefail

# === Configuration ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
APP_NAME="cr2xt"
BUILD_DIR="${PROJECT_ROOT}/build/release"
DIST_DIR="${PROJECT_ROOT}/dist/macos"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# === Default Options ===
CLEAN=false
BUILD=true
SKIP_DEPLOY=false
SKIP_DMG=false
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
UNIVERSAL=false
TARGET_ARCH=""

# === Functions ===

print_help() {
    head -30 "$0" | grep '^#' | sed 's/^# \?//'
}

log_info() {
    echo -e "${CYAN}===${NC} $1 ${CYAN}===${NC}"
}

log_success() {
    echo -e "${GREEN}$1${NC}"
}

log_warning() {
    echo -e "${YELLOW}Warning: $1${NC}"
}

log_error() {
    echo -e "${RED}Error: $1${NC}" >&2
}

log_gray() {
    echo -e "${GRAY}$1${NC}"
}

get_version() {
    local major minor patch git_hash
    # Use sed to extract version numbers (grep picks up "2" from "CR2XT")
    major=$(sed -n 's/^set(CR2XT_VERSION_MAJOR \([0-9]*\))$/\1/p' "${PROJECT_ROOT}/CMakeLists.txt")
    minor=$(sed -n 's/^set(CR2XT_VERSION_MINOR \([0-9]*\))$/\1/p' "${PROJECT_ROOT}/CMakeLists.txt")
    patch=$(sed -n 's/^set(CR2XT_VERSION_PATCH \([0-9]*\))$/\1/p' "${PROJECT_ROOT}/CMakeLists.txt")
    git_hash=$(git -C "$PROJECT_ROOT" rev-parse --short HEAD 2>/dev/null || echo "")
    echo "${major:-0}.${minor:-0}.${patch:-0}${git_hash:+-$git_hash}"
}

find_macdeployqt() {
    # Try PATH first
    if command -v macdeployqt &>/dev/null; then
        which macdeployqt
        return 0
    fi

    # Try Homebrew locations
    local paths=(
        "/opt/homebrew/opt/qt@6/bin/macdeployqt"
        "/opt/homebrew/bin/macdeployqt"
        "/usr/local/opt/qt@6/bin/macdeployqt"
        "/usr/local/bin/macdeployqt"
    )

    for path in "${paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

find_create_dmg() {
    if command -v create-dmg &>/dev/null; then
        which create-dmg
        return 0
    fi

    local paths=(
        "/opt/homebrew/bin/create-dmg"
        "/usr/local/bin/create-dmg"
    )

    for path in "${paths[@]}"; do
        if [ -x "$path" ]; then
            echo "$path"
            return 0
        fi
    done

    return 1
}

verify_architectures() {
    local binary="$1"
    local expected_archs="$2"

    if [ ! -f "$binary" ]; then
        log_error "Binary not found: $binary"
        return 1
    fi

    # Get architectures from the binary
    local actual_archs
    actual_archs=$(lipo -archs "$binary" 2>/dev/null | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')

    # Normalize expected architectures for comparison
    local expected_sorted
    expected_sorted=$(echo "$expected_archs" | tr ';' '\n' | sort | tr '\n' ' ' | sed 's/ $//')

    if [ "$actual_archs" = "$expected_sorted" ]; then
        return 0
    else
        log_warning "Architecture mismatch: expected '$expected_sorted', got '$actual_archs'"
        return 1
    fi
}

# === Parse Arguments ===
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean)
            CLEAN=true
            shift
            ;;
        -b|--build)
            BUILD=true
            shift
            ;;
        --no-build)
            BUILD=false
            shift
            ;;
        -s|--skip-deploy)
            SKIP_DEPLOY=true
            shift
            ;;
        -d|--skip-dmg)
            SKIP_DMG=true
            shift
            ;;
        -j|--jobs)
            JOBS="$2"
            shift 2
            ;;
        -u|--universal)
            UNIVERSAL=true
            shift
            ;;
        -a|--arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            print_help
            exit 1
            ;;
    esac
done

# === Main Script ===

# === Determine Target Architectures ===
if $UNIVERSAL; then
    TARGET_ARCH="arm64;x86_64"
fi

if [ -z "$TARGET_ARCH" ]; then
    # Default to native architecture
    TARGET_ARCH=$(uname -m)
fi

# Determine architecture suffix for DMG naming
if [ "$TARGET_ARCH" = "arm64;x86_64" ] || [ "$TARGET_ARCH" = "x86_64;arm64" ]; then
    ARCH_SUFFIX="universal"
    IS_UNIVERSAL=true
else
    # Single architecture - use as-is
    ARCH_SUFFIX="${TARGET_ARCH}"
    IS_UNIVERSAL=false
fi

VERSION=$(get_version)
echo ""
log_info "Building ${APP_NAME} version ${VERSION}"
echo ""
log_gray "Project root: ${PROJECT_ROOT}"
log_gray "Build directory: ${BUILD_DIR}"
log_gray "Distribution directory: ${DIST_DIR}"
log_gray "Jobs: ${JOBS}"
if $IS_UNIVERSAL; then
    log_gray "Architecture: Universal Binary (arm64 + x86_64)"
else
    log_gray "Architecture: ${TARGET_ARCH}"
fi

# === Clean ===
if $CLEAN; then
    echo ""
    log_info "Cleaning build directories"
    rm -rf "${BUILD_DIR}" "${DIST_DIR}"
    log_success "Cleaned"
fi

# === Build Functions ===

# Build a single architecture
# Usage: build_single_arch <arch> <prefix_path> <build_dir> <install_prefix>
build_single_arch() {
    local arch="$1"
    local prefix_path="$2"
    local build_dir="$3"
    local install_prefix="$4"

    log_info "Configuring CMake for ${arch}"
    log_gray "  Build dir: ${build_dir}"
    log_gray "  Prefix path: ${prefix_path}"

    cmake -B "${build_dir}" -G Ninja -S "${PROJECT_ROOT}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_QT=QT6 \
        -DUSE_COLOR_BACKBUFFER=OFF \
        -DGRAY_BACKBUFFER_BITS=2 \
        -DCMAKE_PREFIX_PATH="${prefix_path}" \
        -DCMAKE_INSTALL_PREFIX="${install_prefix}" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
        -DCMAKE_OSX_ARCHITECTURES="${arch}" \
        -DCRE_BUILD_SHARED=ON \
        -DCRE_BUILD_STATIC=OFF

    echo ""
    log_info "Building ${arch} (${JOBS} jobs)"
    cmake --build "${build_dir}" -j"${JOBS}"

    echo ""
    log_info "Installing ${arch} to ${install_prefix}"
    cmake --build "${build_dir}" --target install
}

# Combine two binaries with lipo
# Usage: lipo_combine <arm64_binary> <x86_64_binary> <output_binary>
lipo_combine() {
    local arm64_bin="$1"
    local x86_64_bin="$2"
    local output_bin="$3"

    if [ ! -f "$arm64_bin" ]; then
        log_error "arm64 binary not found: $arm64_bin"
        return 1
    fi
    if [ ! -f "$x86_64_bin" ]; then
        log_error "x86_64 binary not found: $x86_64_bin"
        return 1
    fi

    lipo -create -output "$output_bin" "$arm64_bin" "$x86_64_bin"
    log_gray "  Created Universal: $(basename "$output_bin")"
}

# === Build ===
if $BUILD; then
    echo ""

    if $IS_UNIVERSAL; then
        # Universal Binary: Build each architecture separately, then combine with lipo
        # This is required because Homebrew libraries are single-architecture
        ARM64_BUILD_DIR="${PROJECT_ROOT}/build/release-arm64"
        X86_64_BUILD_DIR="${PROJECT_ROOT}/build/release-x86_64"
        ARM64_DIST_DIR="${PROJECT_ROOT}/dist/macos-arm64"
        X86_64_DIST_DIR="${PROJECT_ROOT}/dist/macos-x86_64"
        ARM64_APP="${ARM64_DIST_DIR}/${APP_NAME}.app"
        X86_64_APP="${X86_64_DIST_DIR}/${APP_NAME}.app"

        # Clean architecture-specific directories if --clean was specified
        if $CLEAN; then
            rm -rf "${ARM64_BUILD_DIR}" "${X86_64_BUILD_DIR}"
            rm -rf "${ARM64_DIST_DIR}" "${X86_64_DIST_DIR}"
        fi

        # Build arm64
        log_info "Building arm64 architecture"
        build_single_arch "arm64" "/opt/homebrew" "${ARM64_BUILD_DIR}" "${ARM64_APP}"

        echo ""

        # Build x86_64
        log_info "Building x86_64 architecture"
        build_single_arch "x86_64" "/usr/local" "${X86_64_BUILD_DIR}" "${X86_64_APP}"

        echo ""
        log_info "Creating Universal Binary"

        # Use arm64 bundle as base (copy to final location)
        rm -rf "${APP_BUNDLE}"
        mkdir -p "$(dirname "${APP_BUNDLE}")"
        cp -R "${ARM64_APP}" "${APP_BUNDLE}"

        # Combine main executable
        lipo_combine \
            "${ARM64_APP}/Contents/MacOS/crqt" \
            "${X86_64_APP}/Contents/MacOS/crqt" \
            "${APP_BUNDLE}/Contents/MacOS/crqt"

        # Combine crengine-ng framework (if it's already been moved to Contents/Frameworks)
        # or at Library/Frameworks (before relocation)
        ARM64_CRENGINE="${ARM64_APP}/Library/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"
        X86_64_CRENGINE="${X86_64_APP}/Library/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"
        BUNDLE_CRENGINE="${APP_BUNDLE}/Library/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"

        if [ -f "$ARM64_CRENGINE" ] && [ -f "$X86_64_CRENGINE" ]; then
            lipo_combine "$ARM64_CRENGINE" "$X86_64_CRENGINE" "$BUNDLE_CRENGINE"
        fi

        log_success "Universal Binary created"

        # Update BUILD_DIR to point to arm64 build for any post-build steps that need it
        BUILD_DIR="${ARM64_BUILD_DIR}"

    else
        # Single architecture build
        log_info "Configuring CMake"

        # CMAKE_PREFIX_PATH is needed for Homebrew libraries (HarfBuzz, WebP, etc.)
        # Different paths for different architectures:
        #   - arm64: /opt/homebrew (Apple Silicon Homebrew)
        #   - x86_64: /usr/local (Intel Homebrew via Rosetta)
        if [ "$TARGET_ARCH" = "x86_64" ]; then
            CMAKE_PREFIX_PATHS="/usr/local"
        else
            CMAKE_PREFIX_PATHS="/opt/homebrew"
        fi

        cmake -B "${BUILD_DIR}" -G Ninja -S "${PROJECT_ROOT}" \
            -DCMAKE_BUILD_TYPE=Release \
            -DUSE_QT=QT6 \
            -DUSE_COLOR_BACKBUFFER=OFF \
            -DGRAY_BACKBUFFER_BITS=2 \
            -DCMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATHS}" \
            -DCMAKE_INSTALL_PREFIX="${APP_BUNDLE}" \
            -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
            -DCMAKE_OSX_ARCHITECTURES="${TARGET_ARCH}" \
            -DCRE_BUILD_SHARED=ON \
            -DCRE_BUILD_STATIC=OFF

        echo ""
        log_info "Building (${JOBS} jobs)"

        cmake --build "${BUILD_DIR}" -j"${JOBS}"

        echo ""
        log_info "Installing to ${DIST_DIR}"

        cmake --build "${BUILD_DIR}" --target install
    fi
fi

# Verify app bundle exists (CMake installs Contents/ directly into APP_BUNDLE)
if [ ! -f "${APP_BUNDLE}/Contents/MacOS/crqt" ]; then
    log_error "App executable not found at ${APP_BUNDLE}/Contents/MacOS/crqt"
    log_error "Run with --build to build the project first"
    exit 1
fi

# === Verify Architectures ===
echo ""
log_info "Verifying binary architectures"
ACTUAL_ARCHS=$(lipo -archs "${APP_BUNDLE}/Contents/MacOS/crqt" 2>/dev/null || echo "unknown")
log_gray "crqt: ${ACTUAL_ARCHS}"

if $IS_UNIVERSAL; then
    if verify_architectures "${APP_BUNDLE}/Contents/MacOS/crqt" "${TARGET_ARCH}"; then
        log_success "Universal Binary verified"
    else
        log_error "Binary is not a Universal Binary. Ensure dependencies are available for all architectures."
        log_error "For Universal builds, you may need x86_64 libraries installed via Rosetta or cross-compilation."
        exit 1
    fi
fi

# === Fix crengine-ng framework location ===
# CMake installs the framework to APP_BUNDLE/Library/Frameworks but it needs to be in Contents/Frameworks
CRENGINE_SRC="${APP_BUNDLE}/Library/Frameworks/crengine-ng.framework"
CRENGINE_DST="${APP_BUNDLE}/Contents/Frameworks/crengine-ng.framework"
if [ -d "${CRENGINE_SRC}" ]; then
    echo ""
    log_info "Relocating crengine-ng framework"
    mkdir -p "${APP_BUNDLE}/Contents/Frameworks"
    # Remove existing destination to allow non-clean rebuilds
    rm -rf "${CRENGINE_DST}"
    mv "${CRENGINE_SRC}" "${CRENGINE_DST}"
    rmdir "${APP_BUNDLE}/Library/Frameworks" 2>/dev/null || true
    rmdir "${APP_BUNDLE}/Library" 2>/dev/null || true

    # Fix the library path in the executable
    install_name_tool -change \
        "@rpath/crengine-ng.framework/Versions/A/crengine-ng" \
        "@executable_path/../Frameworks/crengine-ng.framework/Versions/A/crengine-ng" \
        "${APP_BUNDLE}/Contents/MacOS/crqt"

    # Also fix the framework's install name
    install_name_tool -id \
        "@executable_path/../Frameworks/crengine-ng.framework/Versions/A/crengine-ng" \
        "${CRENGINE_DST}/Versions/A/crengine-ng"

    log_success "Framework relocated and paths fixed"
fi

# === Clean up extra installed directories ===
# CMake installs include/, lib/, share/ which aren't needed in the app bundle
for extra_dir in include lib share; do
    if [ -d "${APP_BUNDLE}/${extra_dir}" ]; then
        rm -rf "${APP_BUNDLE}/${extra_dir}"
        log_gray "Removed ${extra_dir}/"
    fi
done

# === Qt Deployment ===
if ! $SKIP_DEPLOY; then
    echo ""

    # Check if Qt frameworks already deployed (skip for faster rebuilds)
    QT_CORE_FW="${APP_BUNDLE}/Contents/Frameworks/QtCore.framework"
    if [ -d "${QT_CORE_FW}" ] && [ ! -L "${QT_CORE_FW}" ]; then
        log_info "Qt frameworks already deployed, skipping macdeployqt"
        log_gray "(use --clean to force full redeploy)"
    else
        log_info "Running macdeployqt"

        MACDEPLOYQT=$(find_macdeployqt) || {
            log_error "macdeployqt not found"
            log_error "Install Qt6: brew install qt@6"
            log_error "Or add Qt bin directory to PATH"
            exit 1
        }

        log_gray "Using: ${MACDEPLOYQT}"

        # Run with reduced verbosity, filter duplicate/noise output
        "${MACDEPLOYQT}" "${APP_BUNDLE}" -verbose=1 2>&1 | grep -v "^Log:" | grep -v "^  " || true

        log_success "macdeployqt completed"
    fi

    # Remove unnecessary Qt frameworks from config (pulled in by macdeployqt but not used)
    CONFIG_FILE="${SCRIPT_DIR}/dist-config-macos.json"
    if [ -f "$CONFIG_FILE" ]; then
        EXCLUDE_FRAMEWORKS=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
for fw in config.get('exclude_frameworks', []):
    print(fw)
" 2>/dev/null || echo "")

        if [ -n "$EXCLUDE_FRAMEWORKS" ]; then
            while IFS= read -r fw; do
                FW_PATH="${APP_BUNDLE}/Contents/Frameworks/${fw}.framework"
                if [ -d "${FW_PATH}" ] || [ -L "${FW_PATH}" ]; then
                    rm -rf "${FW_PATH}"
                    log_gray "  Removed unused ${fw}.framework"
                fi
            done <<< "$EXCLUDE_FRAMEWORKS"
        fi
    fi

    # Copy QtDBus framework (required by QtGui on macOS but macdeployqt often creates just a symlink)
    QTDBUS_DST="${APP_BUNDLE}/Contents/Frameworks/QtDBus.framework"
    QTDBUS_SRC="/opt/homebrew/lib/QtDBus.framework"

    # Remove any existing symlink or directory and copy fresh
    if [ -d "${QTDBUS_SRC}" ]; then
        log_gray "Copying QtDBus framework..."
        rm -rf "${QTDBUS_DST}"
        cp -RL "${QTDBUS_SRC}" "${QTDBUS_DST}"
        # Fix the install name
        install_name_tool -id "@executable_path/../Frameworks/QtDBus.framework/Versions/A/QtDBus" \
            "${QTDBUS_DST}/Versions/A/QtDBus" 2>/dev/null || true
        # Sign the framework immediately after modifying
        codesign --force --sign - "${QTDBUS_DST}/Versions/A/QtDBus" 2>/dev/null || true
    fi

    # Fix @rpath references to QtDBus in Qt frameworks
    for fw in QtGui QtWidgets QtCore; do
        FW_PATH="${APP_BUNDLE}/Contents/Frameworks/${fw}.framework/Versions/A/${fw}"
        if [ -f "${FW_PATH}" ]; then
            install_name_tool -change \
                "@rpath/QtDBus.framework/Versions/A/QtDBus" \
                "@executable_path/../Frameworks/QtDBus.framework/Versions/A/QtDBus" \
                "${FW_PATH}" 2>/dev/null || true
            # Re-sign after modifying
            codesign --force --sign - "${FW_PATH}" 2>/dev/null || true
        fi
    done
fi

# === Copy Additional Resources ===
echo ""
log_info "Copying additional resources"

RESOURCES="${APP_BUNDLE}/Contents/Resources"

# Copy crui-defaults.ini
if [ -f "${PROJECT_ROOT}/scripts/crui-defaults.ini" ]; then
    cp "${PROJECT_ROOT}/scripts/crui-defaults.ini" "${RESOURCES}/"
    log_gray "  + crui-defaults.ini"
fi

# Copy fonts from project fonts/ directory (if exists)
# Fonts should be placed in PROJECT_ROOT/fonts/ (NotoSans-*.ttf, Roboto*.ttf, etc.)
CONFIG_FILE="${SCRIPT_DIR}/dist-config-macos.json"
FONTS_SRC="${PROJECT_ROOT}/fonts"

if [ -d "${FONTS_SRC}" ]; then
    mkdir -p "${RESOURCES}/fonts"

    # Read font patterns from config using Python (available on macOS)
    FONT_PATTERNS=$(python3 -c "
import json
with open('$CONFIG_FILE') as f:
    config = json.load(f)
for pattern in config.get('fonts', {}).get('include', []):
    print(pattern)
" 2>/dev/null || echo "")

    if [ -n "$FONT_PATTERNS" ]; then
        font_count=0
        while IFS= read -r pattern; do
            for font in "${FONTS_SRC}/"$pattern; do
                if [ -f "$font" ]; then
                    cp "$font" "${RESOURCES}/fonts/"
                    ((font_count++)) || true
                fi
            done
        done <<< "$FONT_PATTERNS"
        if [ $font_count -gt 0 ]; then
            log_gray "  + fonts/ (${font_count} files)"
        else
            log_gray "  ! No fonts matching patterns in ${FONTS_SRC}/"
        fi
    fi
else
    log_gray "  ! No fonts/ directory found (optional: create ${PROJECT_ROOT}/fonts/)"
fi

# Copy Qt translations (filtered)
if [ -d "${DIST_DIR}/translations" ]; then
    mkdir -p "${RESOURCES}/translations"
    trans_count=0
    for lang in en ru uk cs bg hu nl; do
        src="${DIST_DIR}/translations/qt_${lang}.qm"
        if [ -f "$src" ]; then
            cp "$src" "${RESOURCES}/translations/"
            ((trans_count++)) || true
        fi
    done
    if [ $trans_count -gt 0 ]; then
        log_gray "  + translations/ (${trans_count} files)"
    fi
fi

# === Ad-hoc Code Signing ===
# Always ad-hoc sign if no Developer ID - required on Apple Silicon
if [ -z "${DEVELOPER_ID:-}" ]; then
    echo ""
    log_info "Ad-hoc signing app bundle"

    # Sign all frameworks and dylibs first
    find "${APP_BUNDLE}/Contents/Frameworks" -type f \( -name "*.dylib" -o -perm +111 \) -exec \
        codesign --force --sign - {} \; 2>/dev/null || true

    # Sign framework bundles
    find "${APP_BUNDLE}/Contents/Frameworks" -name "*.framework" -type d -exec \
        codesign --force --sign - {} \; 2>/dev/null || true

    # Sign PlugIns
    find "${APP_BUNDLE}/Contents/PlugIns" -name "*.dylib" -exec \
        codesign --force --sign - {} \; 2>/dev/null || true

    # Sign the main executable and crengine-ng framework
    codesign --force --sign - "${APP_BUNDLE}/Contents/Frameworks/crengine-ng.framework" 2>/dev/null || true
    codesign --force --sign - "${APP_BUNDLE}/Contents/MacOS/crqt"

    # Sign the entire bundle
    codesign --force --sign - "${APP_BUNDLE}"

    log_success "Ad-hoc signing completed"
fi

# === Code Signing (with Developer ID) ===
if [ -n "${DEVELOPER_ID:-}" ]; then
    echo ""
    log_info "Code signing with ${DEVELOPER_ID}"

    # Sign all frameworks and dylibs
    find "${APP_BUNDLE}" -type f \( -name "*.dylib" -o -name "*.framework" \) -exec \
        codesign --force --sign "${DEVELOPER_ID}" --timestamp {} \; 2>/dev/null || true

    # Sign the main executable
    codesign --force --sign "${DEVELOPER_ID}" --timestamp \
        --options runtime \
        "${APP_BUNDLE}/Contents/MacOS/crqt"

    # Sign the entire bundle
    codesign --force --sign "${DEVELOPER_ID}" --timestamp \
        --options runtime \
        "${APP_BUNDLE}"

    log_success "Code signing completed"

    # Verify signature
    codesign --verify --verbose "${APP_BUNDLE}" && log_success "Signature verified"
fi

# === Notarization (Optional) ===
if [ -n "${APPLE_ID:-}" ] && [ -n "${APP_PASSWORD:-}" ] && [ -n "${TEAM_ID:-}" ]; then
    echo ""
    log_info "Submitting for notarization"

    # Create ZIP for notarization
    NOTARIZE_ZIP="${BUILD_DIR}/${APP_NAME}-notarize.zip"
    ditto -c -k --keepParent "${APP_BUNDLE}" "${NOTARIZE_ZIP}"

    # Submit for notarization
    xcrun notarytool submit "${NOTARIZE_ZIP}" \
        --apple-id "${APPLE_ID}" \
        --password "${APP_PASSWORD}" \
        --team-id "${TEAM_ID}" \
        --wait

    # Staple the notarization ticket
    xcrun stapler staple "${APP_BUNDLE}"

    log_success "Notarization completed"

    # Clean up
    rm -f "${NOTARIZE_ZIP}"
fi

# === Create DMG ===
if ! $SKIP_DMG; then
    echo ""
    log_info "Creating DMG"

    # ARCH_SUFFIX was determined earlier based on TARGET_ARCH
    DMG_NAME="${APP_NAME}-${VERSION}-macos-${ARCH_SUFFIX}"
    DMG_PATH="${PROJECT_ROOT}/${DMG_NAME}.dmg"

    # Remove existing DMG
    rm -f "${DMG_PATH}"

    # Check for create-dmg (preferred)
    if CREATE_DMG=$(find_create_dmg); then
        log_gray "Using create-dmg: ${CREATE_DMG}"

        "${CREATE_DMG}" \
            --volname "${APP_NAME} ${VERSION}" \
            --volicon "${APP_BUNDLE}/Contents/Resources/crqt.icns" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 80 \
            --icon "${APP_NAME}.app" 175 190 \
            --hide-extension "${APP_NAME}.app" \
            --app-drop-link 425 190 \
            --no-internet-enable \
            "${DMG_PATH}" \
            "${APP_BUNDLE}" || {
                # create-dmg returns non-zero even on success sometimes
                if [ -f "${DMG_PATH}" ]; then
                    log_warning "create-dmg returned non-zero but DMG was created"
                else
                    log_error "create-dmg failed"
                    exit 1
                fi
            }
    else
        log_gray "create-dmg not found, using hdiutil"
        log_gray "Install create-dmg for prettier DMG: brew install create-dmg"

        # Fallback to hdiutil
        STAGING="${BUILD_DIR}/dmg-staging"
        rm -rf "${STAGING}"
        mkdir -p "${STAGING}"
        cp -R "${APP_BUNDLE}" "${STAGING}/"
        ln -s /Applications "${STAGING}/Applications"

        hdiutil create -volname "${APP_NAME} ${VERSION}" \
            -srcfolder "${STAGING}" \
            -ov -format UDZO \
            "${DMG_PATH}"

        rm -rf "${STAGING}"
    fi

    if [ -f "${DMG_PATH}" ]; then
        DMG_SIZE=$(du -h "${DMG_PATH}" | cut -f1)
        echo ""
        log_success "Created: ${DMG_NAME}.dmg (${DMG_SIZE})"
        log_gray "Location: ${DMG_PATH}"
    fi
fi

# === Summary ===
echo ""
log_info "Distribution Summary"

if [ -d "${APP_BUNDLE}" ]; then
    BUNDLE_SIZE=$(du -sh "${APP_BUNDLE}" | cut -f1)
    FILE_COUNT=$(find "${APP_BUNDLE}" -type f | wc -l | tr -d ' ')
    echo "App bundle: ${APP_BUNDLE}"
    echo "Size: ${BUNDLE_SIZE}"
    echo "Files: ${FILE_COUNT}"
fi

echo ""
log_success "Done"
