#!/bin/bash
#
# generate-dmg-background.sh - Generate DMG background PNG from SVG
#
# Converts assets/dmg-background.svg to PNG files for DMG creation.
# Generates both standard (1x) and Retina (2x) versions.
#
# Requirements: librsvg (brew install librsvg)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
ASSETS_DIR="${PROJECT_ROOT}/assets"

SVG_FILE="${ASSETS_DIR}/dmg-background.svg"
PNG_FILE="${ASSETS_DIR}/dmg-background.png"
PNG_2X_FILE="${ASSETS_DIR}/dmg-background@2x.png"

# DMG window dimensions (must match build-dist-macos.sh)
WIDTH=540
HEIGHT=380

if [ ! -f "$SVG_FILE" ]; then
    echo "Error: SVG file not found: $SVG_FILE" >&2
    exit 1
fi

if ! command -v rsvg-convert &>/dev/null; then
    echo "Error: rsvg-convert not found. Install with: brew install librsvg" >&2
    exit 1
fi

echo "Generating DMG background images..."
echo "  Source: $SVG_FILE"

# Generate 1x version
rsvg-convert -w "$WIDTH" -h "$HEIGHT" "$SVG_FILE" -o "$PNG_FILE"
echo "  Created: $PNG_FILE (${WIDTH}x${HEIGHT})"

# Generate 2x version for Retina displays
rsvg-convert -w $((WIDTH * 2)) -h $((HEIGHT * 2)) "$SVG_FILE" -o "$PNG_2X_FILE"
echo "  Created: $PNG_2X_FILE ($((WIDTH * 2))x$((HEIGHT * 2)))"

echo "Done"
