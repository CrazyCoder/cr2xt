# cmake-build-install.sh - CMake build and install steps for cr2xt
# Sourced by build-dist-windows.ps1
# Arguments: BUILD_DIR JOBS

# Force colored output (CMake/Ninja/GCC don't detect TTY through Start-Process)
export CLICOLOR_FORCE=1
export CMAKE_COLOR_DIAGNOSTICS=ON

BUILD_DIR="$1"
JOBS="${2:-4}"

if [[ -z "$BUILD_DIR" ]]; then
    echo "Usage: source cmake-build-install.sh BUILD_DIR [JOBS]" >&2
    return 1
fi

echo "=== Building ==="
cmake --build "$BUILD_DIR" --target all -j "$JOBS"

echo "=== Installing ==="
cmake --build "$BUILD_DIR" --target install -j "$JOBS"

echo "=== Build completed successfully ==="