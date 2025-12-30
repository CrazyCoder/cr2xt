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
#   -A, --all            Build all targets (arm64, x86_64, and universal) with 3 DMGs
#   -a, --arch ARCH      Target architecture(s) (default: native, or "arm64;x86_64" for universal)
#   -m, --macos-target V Minimum macOS version (default: from dist-config-macos.json)
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
BUILD_ALL=false
TARGET_ARCH=""
MACOS_TARGET=""  # Will be set from config or command line

# === Functions ===

print_help() {
    head -28 "$0" | grep '^#' | sed 's/^# \?//'
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

# Parse JSON array from config file using sed/grep (no Python dependency)
# Usage: json_get_array <json_file> <key> [<nested_key>]
# Example: json_get_array config.json fonts include -> returns each pattern on separate line
json_get_array() {
    local json_file="$1"
    local key="$2"
    local nested_key="${3:-}"

    if [ ! -f "$json_file" ]; then
        return 1
    fi

    local content
    content=$(cat "$json_file")

    if [ -n "$nested_key" ]; then
        # Extract nested object first, then array
        # This handles: "key": { "nested_key": ["item1", "item2"] }
        content=$(echo "$content" | sed -n "/${key}/,/^[[:space:]]*}/p" | \
                  sed -n "/${nested_key}/,/]/p")
    else
        # Extract top-level array: "key": ["item1", "item2"]
        content=$(echo "$content" | sed -n "/${key}/,/]/p")
    fi

    # Extract items from array, handling quoted strings
    echo "$content" | grep -oE '"[^"]*"' | tr -d '"' | grep -v "^${key}$" | grep -v "^${nested_key}$"
}

# Parse a simple JSON string value from config file
# Usage: json_get_value <json_file> <key>
# Example: json_get_value config.json min_macos_version -> returns "11.0"
json_get_value() {
    local json_file="$1"
    local key="$2"

    if [ ! -f "$json_file" ]; then
        return 1
    fi

    # Match "key": "value" and extract value
    grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$json_file" | \
        sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -1
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

# Create DMG for a specific app bundle
# Usage: create_dmg_for_bundle <app_bundle> <arch_suffix> <version>
create_dmg_for_bundle() {
    local bundle="$1"
    local arch_suffix="$2"
    local version="$3"
    local dmg_name="${APP_NAME}-${version}-macos-${arch_suffix}"
    local dmg_path="${PROJECT_ROOT}/dist/${dmg_name}.dmg"

    if [ ! -d "$bundle" ]; then
        log_warning "Bundle not found: $bundle"
        return 1
    fi

    log_gray "Creating: ${dmg_name}.dmg"

    mkdir -p "${PROJECT_ROOT}/dist"
    rm -f "${dmg_path}"

    if CREATE_DMG=$(find_create_dmg); then
        "${CREATE_DMG}" \
            --volname "${APP_NAME} ${version}" \
            --volicon "${bundle}/Contents/Resources/crqt.icns" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "${APP_NAME}.app" 150 190 \
            --hide-extension "${APP_NAME}.app" \
            --app-drop-link 450 190 \
            --no-internet-enable \
            "${dmg_path}" \
            "${bundle}" || {
                if [ ! -f "${dmg_path}" ]; then
                    log_error "create-dmg failed for ${arch_suffix}"
                    return 1
                fi
            }
    else
        local staging="/tmp/cr2xt-dmg-${arch_suffix}-$$"
        rm -rf "${staging}"
        mkdir -p "${staging}"
        cp -R "${bundle}" "${staging}/"
        ln -s /Applications "${staging}/Applications"

        hdiutil create -volname "${APP_NAME}" \
            -srcfolder "${staging}" \
            -ov -format UDZO \
            "${dmg_path}"

        rm -rf "${staging}"
    fi

    if [ -f "${dmg_path}" ]; then
        local dmg_size
        dmg_size=$(du -h "${dmg_path}" | cut -f1)
        log_success "  ${dmg_name}.dmg (${dmg_size})"
        return 0
    fi
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
        -A|--all)
            BUILD_ALL=true
            UNIVERSAL=true  # --all implies universal build
            shift
            ;;
        -a|--arch)
            TARGET_ARCH="$2"
            shift 2
            ;;
        -m|--macos-target)
            MACOS_TARGET="$2"
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

# Update build and dist directories to be architecture-specific
BUILD_DIR="${PROJECT_ROOT}/build/release-${ARCH_SUFFIX}"
DIST_DIR="${PROJECT_ROOT}/dist/macos-${ARCH_SUFFIX}"
APP_BUNDLE="${DIST_DIR}/${APP_NAME}.app"

# === Determine macOS Target Version ===
# Priority: command line arg > config file > hardcoded fallback
if [ -z "$MACOS_TARGET" ]; then
    CONFIG_FILE="${SCRIPT_DIR}/dist-config-macos.json"
    MACOS_TARGET=$(json_get_value "$CONFIG_FILE" "min_macos_version" 2>/dev/null || echo "")
fi
if [ -z "$MACOS_TARGET" ]; then
    MACOS_TARGET="11.0"  # Fallback default
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
log_gray "macOS target: ${MACOS_TARGET}"

# === Clean ===
if $CLEAN; then
    echo ""
    log_info "Cleaning build directories"
    if $IS_UNIVERSAL; then
        # Universal builds use separate arch directories plus final universal output
        rm -rf "${PROJECT_ROOT}/build/release-arm64" "${PROJECT_ROOT}/build/release-x86_64"
        rm -rf "${PROJECT_ROOT}/dist/macos-arm64" "${PROJECT_ROOT}/dist/macos-x86_64"
    else
        rm -rf "${BUILD_DIR}"
    fi
    rm -rf "${DIST_DIR}"
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
        -DCMAKE_OSX_DEPLOYMENT_TARGET="${MACOS_TARGET}" \
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

# Relocate crengine-ng framework from Library/Frameworks to Contents/Frameworks
# and fix library paths in the executable
# Usage: relocate_crengine_framework <app_bundle>
relocate_crengine_framework() {
    local bundle="$1"
    local crengine_src="${bundle}/Library/Frameworks/crengine-ng.framework"
    local crengine_dst="${bundle}/Contents/Frameworks/crengine-ng.framework"

    if [ ! -d "${crengine_src}" ]; then
        return 0  # Nothing to relocate
    fi

    mkdir -p "${bundle}/Contents/Frameworks"
    # Remove existing destination to allow non-clean rebuilds
    rm -rf "${crengine_dst}"
    mv "${crengine_src}" "${crengine_dst}"
    rmdir "${bundle}/Library/Frameworks" 2>/dev/null || true
    rmdir "${bundle}/Library" 2>/dev/null || true

    # Fix the library path in the executable
    install_name_tool -change \
        "@rpath/crengine-ng.framework/Versions/A/crengine-ng" \
        "@executable_path/../Frameworks/crengine-ng.framework/Versions/A/crengine-ng" \
        "${bundle}/Contents/MacOS/crqt"

    # Also fix the framework's install name
    install_name_tool -id \
        "@executable_path/../Frameworks/crengine-ng.framework/Versions/A/crengine-ng" \
        "${crengine_dst}/Versions/A/crengine-ng"
}

# Clean up extra directories from CMake install that aren't needed in app bundle
# Usage: cleanup_extra_dirs <app_bundle>
cleanup_extra_dirs() {
    local bundle="$1"
    for extra_dir in include lib share; do
        rm -rf "${bundle}/${extra_dir}"
    done
}

# Search for a dylib in Homebrew locations matching the required architecture
# Usage: find_homebrew_dylib <dylib_name> <arch>
# Returns: path to the dylib or empty string if not found
find_homebrew_dylib() {
    local dylib_name="$1"
    local arch="$2"
    local search_dirs

    if [ "$arch" = "x86_64" ]; then
        search_dirs="/usr/local/lib /usr/local/opt/*/lib"
    else
        search_dirs="/opt/homebrew/lib /opt/homebrew/opt/*/lib"
    fi

    # Use subshell with nullglob to properly expand globs
    (
        shopt -s nullglob
        for d in $search_dirs; do
            if [ -f "$d/${dylib_name}" ]; then
                local lib_arch
                lib_arch=$(lipo -archs "$d/${dylib_name}" 2>/dev/null)
                if [[ "$lib_arch" == *"$arch"* ]]; then
                    echo "$d/${dylib_name}"
                    return
                fi
            fi
        done
    )
}

# Bundle a dylib: copy, fix install name, sign, and recursively process
# Usage: bundle_dylib <src_path> <dest_path> <fw_dir> <label> <processed_file>
bundle_dylib() {
    local src_path="$1"
    local dest_path="$2"
    local fw_dir="$3"
    local label="$4"
    local processed_file="$5"
    local dylib_name
    dylib_name=$(basename "$dest_path")

    cp "$src_path" "$dest_path"
    chmod 755 "$dest_path"
    log_gray "    Bundled${label}: ${dylib_name}"

    install_name_tool -id "@executable_path/../Frameworks/${dylib_name}" \
        "$dest_path" 2>/dev/null || true
    codesign --force --sign - "$dest_path" 2>/dev/null || true

    # Recursively process this library's dependencies
    fix_homebrew_dependencies "$dest_path" "$fw_dir" "$processed_file"
}

# Bundle and fix all Homebrew dependencies for a binary (recursively)
# Also fixes @rpath and @executable_path references to bundled libraries
# Usage: fix_homebrew_dependencies <binary_path> <frameworks_dir> [processed_list_file]
fix_homebrew_dependencies() {
    local binary="$1"
    local fw_dir="$2"
    local processed_file="${3:-}"

    # Create temp file to track processed libraries (avoid infinite recursion)
    if [ -z "$processed_file" ]; then
        processed_file=$(mktemp)
        trap "rm -f '$processed_file'" RETURN
    fi

    # Skip if already processed
    if grep -qxF "$binary" "$processed_file" 2>/dev/null; then
        return 0
    fi
    echo "$binary" >> "$processed_file"

    # Determine architecture of the binary
    local binary_arch
    binary_arch=$(lipo -archs "$binary" 2>/dev/null | awk '{print $1}')

    # Get all dependencies
    local all_deps
    all_deps=$(otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}')

    local dep dep_name bundled_path
    for dep in $all_deps; do
        dep_name=$(basename "$dep")
        bundled_path="${fw_dir}/${dep_name}"

        # Skip frameworks and system libraries
        [[ "$dep" == *".framework"* ]] && continue
        [[ "$dep" == "/usr/lib/"* ]] && continue
        [[ "$dep" == "/System/"* ]] && continue

        # Handle absolute Homebrew paths
        if [[ "$dep" == /opt/homebrew/* ]] || [[ "$dep" == /usr/local/opt/* ]]; then
            if [ ! -f "$bundled_path" ] && [ -f "$dep" ]; then
                bundle_dylib "$dep" "$bundled_path" "$fw_dir" "" "$processed_file"
            fi
            install_name_tool -change "$dep" \
                "@executable_path/../Frameworks/${dep_name}" \
                "$binary" 2>/dev/null || true

        # Handle @rpath or @executable_path references to missing libraries
        elif [[ "$dep" == @rpath/* ]] || [[ "$dep" == @executable_path/../Frameworks/* ]]; then
            if [ ! -f "$bundled_path" ]; then
                local src_path
                src_path=$(find_homebrew_dylib "$dep_name" "$binary_arch")
                if [ -n "$src_path" ]; then
                    local label=""
                    [[ "$dep" == @rpath/* ]] && label=" (rpath)"
                    [[ "$dep" == @executable_path/* ]] && label=" (exec_path)"
                    bundle_dylib "$src_path" "$bundled_path" "$fw_dir" "$label" "$processed_file"
                else
                    log_warning "    Cannot find ${binary_arch} version of ${dep_name}"
                fi
            fi
            if [ -f "$bundled_path" ]; then
                install_name_tool -change "$dep" \
                    "@executable_path/../Frameworks/${dep_name}" \
                    "$binary" 2>/dev/null || true
            fi
        fi
    done
}

# Fix all crengine-ng framework dependencies
# Usage: fix_crengine_dependencies <app_bundle>
fix_crengine_dependencies() {
    local bundle="$1"
    local crengine_bin="${bundle}/Contents/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"
    local fw_dir="${bundle}/Contents/Frameworks"

    if [ ! -f "$crengine_bin" ]; then
        return 0
    fi

    log_gray "  Fixing crengine-ng dependencies..."
    fix_homebrew_dependencies "$crengine_bin" "$fw_dir"

    # Also fix any bundled dylibs that might have Homebrew references
    local dylib
    for dylib in "${fw_dir}"/*.dylib; do
        if [ -f "$dylib" ]; then
            fix_homebrew_dependencies "$dylib" "$fw_dir"
        fi
    done

    # Re-sign crengine-ng after modifications
    codesign --force --sign - "$crengine_bin" 2>/dev/null || true
}

# Copy QtDBus framework and fix library paths
# Usage: copy_qtdbus_framework <app_bundle> <qt_lib_path>
copy_qtdbus_framework() {
    local bundle="$1"
    local qt_lib_path="$2"
    local qtdbus_dst="${bundle}/Contents/Frameworks/QtDBus.framework"
    local qtdbus_src="${qt_lib_path}/QtDBus.framework"
    local fw_dir="${bundle}/Contents/Frameworks"

    if [ ! -d "${qtdbus_src}" ]; then
        return 0  # QtDBus not available
    fi

    log_gray "    Copying QtDBus framework..."
    rm -rf "${qtdbus_dst}"

    # Use ditto to preserve framework structure, or copy and fix manually
    if command -v ditto &>/dev/null; then
        ditto "${qtdbus_src}" "${qtdbus_dst}"
    else
        cp -RL "${qtdbus_src}" "${qtdbus_dst}"
        # Fix framework structure: top-level files should be symlinks
        rm -f "${qtdbus_dst}/QtDBus"
        rm -rf "${qtdbus_dst}/Resources"
        rm -rf "${qtdbus_dst}/Versions/Current"
        ln -sf A "${qtdbus_dst}/Versions/Current"
        ln -sf Versions/Current/QtDBus "${qtdbus_dst}/QtDBus"
        ln -sf Versions/Current/Resources "${qtdbus_dst}/Resources"
    fi

    # Remove development files not needed at runtime
    rm -rf "${qtdbus_dst}/Headers"
    rm -rf "${qtdbus_dst}/Versions/A/Headers"
    rm -f "${qtdbus_dst}/Versions/Current/Headers" 2>/dev/null || true

    # Fix the install name
    install_name_tool -id "@executable_path/../Frameworks/QtDBus.framework/Versions/A/QtDBus" \
        "${qtdbus_dst}/Versions/A/QtDBus" 2>/dev/null || true

    # Find and bundle libdbus dependency (QtDBus links to Homebrew's libdbus)
    local libdbus_path
    libdbus_path=$(otool -L "${qtdbus_dst}/Versions/A/QtDBus" 2>/dev/null | grep -o '/.*libdbus[^[:space:]]*' | head -1)

    if [ -n "$libdbus_path" ] && [ -f "$libdbus_path" ]; then
        local libdbus_name
        libdbus_name=$(basename "$libdbus_path")
        log_gray "    Bundling ${libdbus_name}..."

        # Copy libdbus to Frameworks (remove existing first for non-clean rebuilds)
        rm -f "${fw_dir}/${libdbus_name}"
        cp "$libdbus_path" "${fw_dir}/${libdbus_name}"

        # Fix libdbus install name
        install_name_tool -id "@executable_path/../Frameworks/${libdbus_name}" \
            "${fw_dir}/${libdbus_name}" 2>/dev/null || true

        # Fix QtDBus reference to libdbus
        install_name_tool -change "$libdbus_path" \
            "@executable_path/../Frameworks/${libdbus_name}" \
            "${qtdbus_dst}/Versions/A/QtDBus" 2>/dev/null || true

        # Sign the bundled libdbus
        codesign --force --sign - "${fw_dir}/${libdbus_name}" 2>/dev/null || true
    fi
}

# Fix @rpath references to QtDBus in Qt frameworks
# Usage: fix_qtdbus_references <app_bundle> [sign]
fix_qtdbus_references() {
    local bundle="$1"
    local sign="${2:-false}"

    for fw in QtGui QtWidgets QtCore; do
        local fw_path="${bundle}/Contents/Frameworks/${fw}.framework/Versions/A/${fw}"
        if [ -f "${fw_path}" ]; then
            install_name_tool -change \
                "@rpath/QtDBus.framework/Versions/A/QtDBus" \
                "@executable_path/../Frameworks/QtDBus.framework/Versions/A/QtDBus" \
                "${fw_path}" 2>/dev/null || true
            # Re-sign after modifying if requested
            if [ "$sign" = "true" ]; then
                codesign --force --sign - "${fw_path}" 2>/dev/null || true
            fi
        fi
    done
}

# Remove dylibs that don't match the expected architecture
# Usage: remove_wrong_arch_dylibs <app_bundle> <expected_arch>
remove_wrong_arch_dylibs() {
    local bundle="$1"
    local expected_arch="$2"
    local fw_dir="${bundle}/Contents/Frameworks"

    for dylib in "${fw_dir}"/*.dylib; do
        if [ -f "$dylib" ]; then
            local actual_arch
            actual_arch=$(lipo -archs "$dylib" 2>/dev/null)
            # Check if expected architecture is present
            if [[ "$actual_arch" != *"$expected_arch"* ]]; then
                log_warning "    Removing wrong-arch $(basename "$dylib") (has: $actual_arch, need: $expected_arch)"
                rm -f "$dylib"
            fi
        fi
    done
}

# Deploy Qt to an app bundle using architecture-specific macdeployqt
# Usage: deploy_qt_to_bundle <app_bundle> <arch>
deploy_qt_to_bundle() {
    local bundle="$1"
    local arch="$2"
    local macdeployqt_path
    local qt_lib_path

    if [ "$arch" = "arm64" ]; then
        macdeployqt_path="/opt/homebrew/opt/qt@6/bin/macdeployqt"
        qt_lib_path="/opt/homebrew/lib"
    else
        macdeployqt_path="/usr/local/opt/qt@6/bin/macdeployqt"
        qt_lib_path="/usr/local/lib"
    fi

    if [ ! -x "$macdeployqt_path" ]; then
        log_error "macdeployqt not found for $arch at $macdeployqt_path"
        return 1
    fi

    # Clean stale Qt artifacts from previous builds before macdeployqt runs
    local fw_dir="${bundle}/Contents/Frameworks"
    local plugins_dir="${bundle}/Contents/PlugIns"

    if [ -d "$fw_dir" ]; then
        rm -f "${fw_dir}"/*.dylib 2>/dev/null || true
        # Remove Qt frameworks (but keep crengine-ng.framework)
        for fw in "${fw_dir}"/Qt*.framework; do
            [ -d "$fw" ] && rm -rf "$fw"
        done
    fi

    # Remove Qt plugins (macdeployqt will re-copy them)
    if [ -d "$plugins_dir" ]; then
        rm -rf "$plugins_dir"
    fi

    log_gray "  Using: ${macdeployqt_path}"
    "${macdeployqt_path}" "${bundle}" -verbose=1 2>&1 | grep -v "^Log:" | grep -v "^  " | grep -v "^ERROR:" || true

    # Remove any wrong-architecture dylibs that macdeployqt might have bundled
    remove_wrong_arch_dylibs "${bundle}" "$arch"

    # Apply framework exclusions from config
    apply_framework_exclusions "${bundle}"

    # Copy QtDBus framework and fix references
    copy_qtdbus_framework "${bundle}" "${qt_lib_path}"
    fix_qtdbus_references "${bundle}"

    # Fix crengine-ng Homebrew dependencies
    fix_crengine_dependencies "${bundle}"

    # Re-sign entire bundle after all modifications (install_name_tool invalidates signatures)
    log_gray "  Re-signing bundle..."
    codesign --force --deep --sign - "${bundle}" 2>/dev/null || true
}

# Remove unused frameworks and dylibs based on dist-config-macos.json
# Usage: apply_framework_exclusions <app_bundle>
apply_framework_exclusions() {
    local bundle="$1"
    local config_file="${SCRIPT_DIR}/dist-config-macos.json"
    local fw_dir="${bundle}/Contents/Frameworks"

    if [ ! -f "$config_file" ]; then
        return 0
    fi

    # Remove excluded frameworks
    local exclude_frameworks
    exclude_frameworks=$(json_get_array "$config_file" "exclude_frameworks")
    if [ -n "$exclude_frameworks" ]; then
        while IFS= read -r fw; do
            [ -z "$fw" ] && continue
            local fw_path="${fw_dir}/${fw}.framework"
            if [ -d "${fw_path}" ] || [ -L "${fw_path}" ]; then
                rm -rf "${fw_path}"
                log_gray "    Removed unused ${fw}.framework"
            fi
        done <<< "$exclude_frameworks"
    fi

    # Remove excluded dylibs (supports glob patterns like libssl.*.dylib)
    local exclude_dylibs
    exclude_dylibs=$(json_get_array "$config_file" "exclude_dylibs")
    if [ -n "$exclude_dylibs" ]; then
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
            # Use find with -name to handle glob patterns
            while IFS= read -r dylib; do
                [ -z "$dylib" ] && continue
                rm -f "$dylib"
                log_gray "    Removed unused $(basename "$dylib")"
            done < <(find "${fw_dir}" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)
        done <<< "$exclude_dylibs"
    fi
}

# Create Universal frameworks by combining arm64 and x86_64 versions
# Usage: create_universal_frameworks <arm64_app> <x86_64_app> <output_app>
create_universal_frameworks() {
    local arm64_app="$1"
    local x86_64_app="$2"
    local output_app="$3"
    local arm64_fw="${arm64_app}/Contents/Frameworks"
    local x86_64_fw="${x86_64_app}/Contents/Frameworks"
    local output_fw="${output_app}/Contents/Frameworks"

    log_info "Creating Universal frameworks"

    # Find all frameworks and dylibs in arm64 bundle
    for fw_path in "${arm64_fw}"/*.framework; do
        if [ -d "$fw_path" ]; then
            local fw_name=$(basename "$fw_path" .framework)
            local arm64_bin="${fw_path}/Versions/A/${fw_name}"
            local x86_64_bin="${x86_64_fw}/${fw_name}.framework/Versions/A/${fw_name}"
            local output_bin="${output_fw}/${fw_name}.framework/Versions/A/${fw_name}"

            if [ -f "$arm64_bin" ] && [ -f "$x86_64_bin" ]; then
                lipo_combine "$arm64_bin" "$x86_64_bin" "$output_bin"
            elif [ -f "$arm64_bin" ]; then
                log_warning "  ${fw_name}: x86_64 version not found, using arm64 only"
            fi
        fi
    done

    # Handle dylibs in Frameworks directory
    for dylib in "${arm64_fw}"/*.dylib; do
        if [ -f "$dylib" ]; then
            local dylib_name=$(basename "$dylib")
            local arm64_bin="$dylib"
            local x86_64_bin="${x86_64_fw}/${dylib_name}"
            local output_bin="${output_fw}/${dylib_name}"

            if [ -f "$x86_64_bin" ]; then
                lipo_combine "$arm64_bin" "$x86_64_bin" "$output_bin"
            else
                log_warning "  ${dylib_name}: x86_64 version not found, using arm64 only"
            fi
        fi
    done

    # Check for x86_64-only dylibs (not in arm64 bundle)
    for dylib in "${x86_64_fw}"/*.dylib; do
        if [ -f "$dylib" ]; then
            local dylib_name=$(basename "$dylib")
            local arm64_bin="${arm64_fw}/${dylib_name}"
            local output_bin="${output_fw}/${dylib_name}"

            if [ ! -f "$arm64_bin" ]; then
                log_warning "  ${dylib_name}: arm64 version not found, copying x86_64 only"
                cp "$dylib" "$output_bin"
                # Re-sign after copying
                codesign --force --sign - "$output_bin" 2>/dev/null || true
            fi
        fi
    done

    # Handle PlugIns
    local arm64_plugins="${arm64_app}/Contents/PlugIns"
    local x86_64_plugins="${x86_64_app}/Contents/PlugIns"
    local output_plugins="${output_app}/Contents/PlugIns"

    if [ -d "$arm64_plugins" ]; then
        find "$arm64_plugins" -name "*.dylib" -type f | while read -r arm64_plugin; do
            local rel_path="${arm64_plugin#${arm64_plugins}/}"
            local x86_64_plugin="${x86_64_plugins}/${rel_path}"
            local output_plugin="${output_plugins}/${rel_path}"

            if [ -f "$x86_64_plugin" ]; then
                lipo_combine "$arm64_plugin" "$x86_64_plugin" "$output_plugin"
            fi
        done
    fi
}

# === Build ===
if $BUILD; then
    echo ""

    if $IS_UNIVERSAL; then
        # Universal Binary: Build each architecture separately, deploy Qt, then combine with lipo
        # This is required because Homebrew libraries are single-architecture
        ARM64_BUILD_DIR="${PROJECT_ROOT}/build/release-arm64"
        X86_64_BUILD_DIR="${PROJECT_ROOT}/build/release-x86_64"
        ARM64_DIST_DIR="${PROJECT_ROOT}/dist/macos-arm64"
        X86_64_DIST_DIR="${PROJECT_ROOT}/dist/macos-x86_64"
        ARM64_APP="${ARM64_DIST_DIR}/${APP_NAME}.app"
        X86_64_APP="${X86_64_DIST_DIR}/${APP_NAME}.app"

        # Build arm64
        log_info "Building arm64 architecture"
        build_single_arch "arm64" "/opt/homebrew" "${ARM64_BUILD_DIR}" "${ARM64_APP}"

        # Prepare arm64 bundle for Qt deployment
        relocate_crengine_framework "${ARM64_APP}"
        cleanup_extra_dirs "${ARM64_APP}"

        # Deploy Qt to arm64 bundle
        echo ""
        log_info "Deploying Qt to arm64 bundle"
        deploy_qt_to_bundle "${ARM64_APP}" "arm64"

        echo ""

        # Build x86_64
        log_info "Building x86_64 architecture"
        build_single_arch "x86_64" "/usr/local" "${X86_64_BUILD_DIR}" "${X86_64_APP}"

        # Prepare x86_64 bundle for Qt deployment
        relocate_crengine_framework "${X86_64_APP}"
        cleanup_extra_dirs "${X86_64_APP}"

        # Deploy Qt to x86_64 bundle
        echo ""
        log_info "Deploying Qt to x86_64 bundle"
        deploy_qt_to_bundle "${X86_64_APP}" "x86_64"

        echo ""
        log_info "Creating Universal Binary"

        # Use arm64 bundle as base (copy to final location)
        # Use ditto to preserve framework symlinks properly
        rm -rf "${APP_BUNDLE}"
        mkdir -p "$(dirname "${APP_BUNDLE}")"
        ditto "${ARM64_APP}" "${APP_BUNDLE}"

        # Combine main executable
        lipo_combine \
            "${ARM64_APP}/Contents/MacOS/crqt" \
            "${X86_64_APP}/Contents/MacOS/crqt" \
            "${APP_BUNDLE}/Contents/MacOS/crqt"

        # Combine crengine-ng framework
        ARM64_CRENGINE="${ARM64_APP}/Contents/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"
        X86_64_CRENGINE="${X86_64_APP}/Contents/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"
        BUNDLE_CRENGINE="${APP_BUNDLE}/Contents/Frameworks/crengine-ng.framework/Versions/A/crengine-ng"

        if [ -f "$ARM64_CRENGINE" ] && [ -f "$X86_64_CRENGINE" ]; then
            lipo_combine "$ARM64_CRENGINE" "$X86_64_CRENGINE" "$BUNDLE_CRENGINE"
        fi

        # Combine all Qt frameworks and plugins
        create_universal_frameworks "${ARM64_APP}" "${X86_64_APP}" "${APP_BUNDLE}"

        # Apply framework exclusions to final bundle (in case any were missed)
        apply_framework_exclusions "${APP_BUNDLE}"

        log_success "Universal Binary created"

        # Update BUILD_DIR to point to arm64 build for any post-build steps that need it
        BUILD_DIR="${ARM64_BUILD_DIR}"

        # Mark that Qt deployment was already done for Universal builds
        SKIP_DEPLOY=true

    else
        # Single architecture build
        # CMAKE_PREFIX_PATH is needed for Homebrew libraries (HarfBuzz, WebP, etc.)
        # Different paths for different architectures:
        #   - arm64: /opt/homebrew (Apple Silicon Homebrew)
        #   - x86_64: /usr/local (Intel Homebrew via Rosetta)
        if [ "$TARGET_ARCH" = "x86_64" ]; then
            CMAKE_PREFIX_PATHS="/usr/local"
        else
            CMAKE_PREFIX_PATHS="/opt/homebrew"
        fi

        build_single_arch "${TARGET_ARCH}" "${CMAKE_PREFIX_PATHS}" "${BUILD_DIR}" "${APP_BUNDLE}"
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
if [ -d "${APP_BUNDLE}/Library/Frameworks/crengine-ng.framework" ]; then
    echo ""
    log_info "Relocating crengine-ng framework"
    relocate_crengine_framework "${APP_BUNDLE}"
    log_success "Framework relocated and paths fixed"
fi

# === Clean up extra installed directories ===
# CMake installs include/, lib/, share/ which aren't needed in the app bundle
cleanup_extra_dirs "${APP_BUNDLE}"

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
    apply_framework_exclusions "${APP_BUNDLE}"

    # Determine Qt library path based on target architecture
    if [ "$TARGET_ARCH" = "x86_64" ]; then
        QT_LIB_PATH="/usr/local/lib"
    else
        QT_LIB_PATH="/opt/homebrew/lib"
    fi

    # Copy QtDBus framework (required by QtGui on macOS but macdeployqt often creates just a symlink)
    copy_qtdbus_framework "${APP_BUNDLE}" "${QT_LIB_PATH}"
    # Sign QtDBus after copying
    codesign --force --sign - "${APP_BUNDLE}/Contents/Frameworks/QtDBus.framework/Versions/A/QtDBus" 2>/dev/null || true

    # Fix @rpath references to QtDBus in Qt frameworks (with signing)
    fix_qtdbus_references "${APP_BUNDLE}" "true"

    # Fix crengine-ng Homebrew dependencies
    echo ""
    log_info "Fixing crengine-ng dependencies"
    fix_crengine_dependencies "${APP_BUNDLE}"
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

    # Read font patterns from config using native shell parsing
    FONT_PATTERNS=$(json_get_array "$CONFIG_FILE" "fonts" "include")

    if [ -n "$FONT_PATTERNS" ]; then
        font_count=0
        while IFS= read -r pattern; do
            [ -z "$pattern" ] && continue
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

    if ! find_create_dmg &>/dev/null; then
        log_gray "create-dmg not found, using hdiutil"
        log_gray "Install create-dmg for prettier DMG: brew install create-dmg"
    fi

    if $BUILD_ALL; then
        # Create DMGs for all three targets (bundles already exist from universal build)
        create_dmg_for_bundle "${PROJECT_ROOT}/dist/macos-arm64/${APP_NAME}.app" "arm64" "${VERSION}"
        create_dmg_for_bundle "${PROJECT_ROOT}/dist/macos-x86_64/${APP_NAME}.app" "x86_64" "${VERSION}"
        create_dmg_for_bundle "${PROJECT_ROOT}/dist/macos-universal/${APP_NAME}.app" "universal" "${VERSION}"
    else
        # Single target DMG
        create_dmg_for_bundle "${APP_BUNDLE}" "${ARCH_SUFFIX}" "${VERSION}"
    fi
fi

# === Summary ===
echo ""
log_info "Distribution Summary"

print_bundle_info() {
    local bundle="$1"
    local label="$2"
    if [ -d "$bundle" ]; then
        local size
        size=$(du -sh "$bundle" | cut -f1)
        echo "  ${label}: ${size}"
    fi
}

if $BUILD_ALL; then
    echo "App bundles:"
    print_bundle_info "${PROJECT_ROOT}/dist/macos-arm64/${APP_NAME}.app" "arm64"
    print_bundle_info "${PROJECT_ROOT}/dist/macos-x86_64/${APP_NAME}.app" "x86_64"
    print_bundle_info "${PROJECT_ROOT}/dist/macos-universal/${APP_NAME}.app" "universal"
elif [ -d "${APP_BUNDLE}" ]; then
    BUNDLE_SIZE=$(du -sh "${APP_BUNDLE}" | cut -f1)
    FILE_COUNT=$(find "${APP_BUNDLE}" -type f | wc -l | tr -d ' ')
    echo "App bundle: ${APP_BUNDLE}"
    echo "Size: ${BUNDLE_SIZE}"
    echo "Files: ${FILE_COUNT}"
fi

echo ""
log_success "Done"
