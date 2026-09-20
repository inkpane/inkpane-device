#!/bin/sh
# Removes the InkPane KOReader plugin. Only ever touches the
# inkpane.koplugin folder this package installed.

set -e

for candidate in "/mnt/us/koreader" "/mnt/onboard/.adds/koreader" "/koreader"; do
    if [ -d "$candidate/plugins/inkpane.koplugin" ]; then
        rm -rf "$candidate/plugins/inkpane.koplugin"
    fi
done

echo "InkPane removed."
