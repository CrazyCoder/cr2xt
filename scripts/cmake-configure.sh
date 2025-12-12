# cmake-configure.sh - CMake configure step for cr2xt
# Sourced by build-dist-windows.ps1
# Arguments: PROJECT_ROOT BUILD_DIR INSTALL_PREFIX

# Force colored output (CMake/Ninja/GCC don't detect TTY through Start-Process)
export CLICOLOR_FORCE=1
export CMAKE_COLOR_DIAGNOSTICS=ON

PROJECT_ROOT="$1"
BUILD_DIR="$2"
INSTALL_PREFIX="$3"

if [[ -z "$PROJECT_ROOT" || -z "$BUILD_DIR" || -z "$INSTALL_PREFIX" ]]; then
    echo "Usage: source cmake-configure.sh PROJECT_ROOT BUILD_DIR INSTALL_PREFIX" >&2
    return 1
fi

echo "=== Configuring ==="
cmake -S "$PROJECT_ROOT" -B "$BUILD_DIR" -G "Ninja" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCON_DEBUG:BOOL=OFF \
    "-DCMAKE_INSTALL_PREFIX:PATH=$INSTALL_PREFIX"