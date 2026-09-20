#!/bin/sh
# Installs the InkPane KOReader plugin.
# Runs relative to the unpacked package directory, which contains this
# script alongside manifest.json and the inkpane.koplugin folder.

set -e

find_koreader_dir() {
    for candidate in "/mnt/us/koreader" "/mnt/onboard/.adds/koreader" "/koreader"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

KOREADER_DIR=$(find_koreader_dir) || {
    echo "Could not find a KOReader installation. Install KOReader first (;kpm install koreader)."
    exit 1
}

PLUGINS_DIR="$KOREADER_DIR/plugins"
mkdir -p "$PLUGINS_DIR"

# Clean reinstall so an upgrade never leaves stale files behind.
rm -rf "$PLUGINS_DIR/inkpane.koplugin"
cp -r ./inkpane.koplugin "$PLUGINS_DIR/inkpane.koplugin"

echo "InkPane installed. Restart KOReader, then open Tools > InkPane."
