#!/bin/bash
# Extract the Headers folder of CsoundLib64.framework from the official
# universal installer of Csound $CSOUND_VERSION into $DEST. The installer
# also holds the headers Csound generates at build time (float-version.h,
# version.h), which the repository's include/ lacks.
set -euo pipefail
: "${CSOUND_VERSION:?}" "${DEST:?}"
[[ "$CSOUND_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::invalid Csound version '$CSOUND_VERSION'"; exit 1; }
work="$RUNNER_TEMP/csound-installer"
mkdir -p "$work"
curl -sSfL -o "$work/csound.dmg" \
    "https://github.com/csound/csound/releases/download/$CSOUND_VERSION/Csound-MacOS-universal-$CSOUND_VERSION.dmg"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$work/dmg" "$work/csound.dmg"
pkg=$(find "$work/dmg" -maxdepth 2 -name '*.pkg' | head -n 1)
[ -n "$pkg" ] || { echo "::error::no .pkg in the Csound dmg"; ls -R "$work/dmg" | head -n 40; exit 1; }
pkgutil --expand-full "$pkg" "$work/pkg"
hdiutil detach -quiet "$work/dmg"
csdl=$(find "$work/pkg" -name csdl.h -path '*CsoundLib64.framework*' | head -n 1)
[ -n "$csdl" ] || { echo "::error::no CsoundLib64.framework headers in the Csound installer"; exit 1; }
cp -R "$(dirname "$csdl")/" "$DEST"
