#!/bin/sh
# Builds the InkPane KPM package and (re)generates the static repo index
# under public/kpm/, ready to be served by InkPane.
#
# The source tree deliberately keeps the proven RTC implementation in main.lua.
# The installed package uses main-entry.lua as main.lua, and ships that proven
# implementation beside it as main_rtc.lua. This lets RTC devices run the
# known-good path unchanged while non-RTC devices load nonrtc.lua.
#
# Usage: sh clients/koreader/kpm/build.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# kpm/ and inkpane.koplugin/ are siblings in both trees this script has to run
# in: clients/koreader/ here, and the root of the standalone device client repo.
CLIENT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PACKAGE_SRC="$SCRIPT_DIR/package"
PLUGIN_SRC="$CLIENT_ROOT/inkpane.koplugin"

# Here the built package feeds the repo index InkPane serves from public/kpm. A
# standalone checkout has no such directory and just wants the artifact.
if [ -d "$CLIENT_ROOT/../../public" ]; then
    REPO_OUT="$(cd "$CLIENT_ROOT/../.." && pwd)/public/kpm"
else
    REPO_OUT="$CLIENT_ROOT/build/kpm"
fi
mkdir -p "$REPO_OUT"

VERSION=$(sed -n 's/.*"version": \[\(.*\)\].*/\1/p' "$PACKAGE_SRC/manifest.json" | tr -d ' ' | tr ',' '.')
if [ -z "$VERSION" ]; then
    echo "Could not read version from $PACKAGE_SRC/manifest.json" >&2
    exit 1
fi

ARTIFACT_NAME="inkpane_${VERSION}_kindleany.kpkg"
ARTIFACT_DIR="$REPO_OUT/packages/inkpane/artifacts"
ARTIFACT_PATH="$ARTIFACT_DIR/$ARTIFACT_NAME"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp "$PACKAGE_SRC/manifest.json" "$STAGE/manifest.json"
cp "$PACKAGE_SRC/install.sh" "$STAGE/install.sh"
cp "$PACKAGE_SRC/uninstall.sh" "$STAGE/uninstall.sh"

mkdir -p "$STAGE/inkpane.koplugin"
cp "$PLUGIN_SRC/main-entry.lua" "$STAGE/inkpane.koplugin/main.lua"
cp "$PLUGIN_SRC/main.lua" "$STAGE/inkpane.koplugin/main_rtc.lua"
# main-entry.lua calls error() if this file is missing, so leaving it out does
# not degrade the plugin -- it stops it loading at all, on every device. It was
# added to the source tree after this script was last run, which is exactly the
# kind of drift the check below now refuses to ship.
cp "$PLUGIN_SRC/pairing.lua" "$STAGE/inkpane.koplugin/pairing.lua"
cp "$PLUGIN_SRC/nonrtc.lua" "$STAGE/inkpane.koplugin/nonrtc.lua"
cp "$PLUGIN_SRC/_meta.lua" "$STAGE/inkpane.koplugin/_meta.lua"
cp "$PLUGIN_SRC/THIRD_PARTY_NOTICES" "$STAGE/inkpane.koplugin/THIRD_PARTY_NOTICES"
# AGPL: every copy of the plugin ships the licence. It lives beside the plugin
# here and at the root of the standalone device repo; the bytes are the same.
if [ -f "$PLUGIN_SRC/LICENSE" ]; then
    cp "$PLUGIN_SRC/LICENSE" "$STAGE/inkpane.koplugin/LICENSE"
else
    cp "$CLIENT_ROOT/LICENSE" "$STAGE/inkpane.koplugin/LICENSE"
fi

# Refuse to ship a package the entry point cannot load. main-entry.lua names its
# siblings at runtime, so a file missing from the staging directory is not
# discovered until a device tries to start the plugin -- and then it fails
# completely rather than partially. Read the names out of the entry point itself
# instead of keeping a second list in sync with it by hand.
missing=""
for required in $(grep -o 'plugin_dir \.\. "[A-Za-z0-9_]*\.lua"' "$PLUGIN_SRC/main-entry.lua" | sed 's/.*"\(.*\)"/\1/'); do
    [ -f "$STAGE/inkpane.koplugin/$required" ] || missing="$missing $required"
done
if [ -n "$missing" ]; then
    echo "Refusing to build: main-entry.lua loads files this package would not contain:$missing" >&2
    exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR"/inkpane_*.kpkg

(cd "$STAGE" && tar czf "$ARTIFACT_PATH" manifest.json install.sh uninstall.sh inkpane.koplugin)

cat > "$REPO_OUT/manifest.json" <<EOF
{
  "manifest_version": 3,
  "id": "inkpane-repo",
  "name": "InkPane",
  "description": "InkPane packages for KOReader.",
  "packages": {
    "inkpane": {
      "name": "InkPane",
      "author": "InkPane",
      "description": "Pairs this e-reader with InkPane and keeps its dashboard image updated.",
      "artifacts": [
        {
          "url": "packages/inkpane/artifacts/${ARTIFACT_NAME}",
          "version": [$(sed -n 's/.*"version": \[\(.*\)\].*/\1/p' "$PACKAGE_SRC/manifest.json")],
          "dependencies": [],
          "supported_platforms": null
        }
      ]
    }
  }
}
EOF

echo "Built $ARTIFACT_PATH"
echo "Repo index at $REPO_OUT/manifest.json"
