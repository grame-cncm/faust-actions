#!/bin/bash
# Fetch the Max SDK headers into $DEST: Cycling74/max-sdk holds the examples
# only; the headers and the MaxAudioAPI framework faust2max6 needs are in
# max-sdk-base/c74support.
set -euo pipefail
: "${DEST:?}"
git clone -q --depth 1 https://github.com/Cycling74/max-sdk-base "$DEST"
echo "max-sdk-base commit: $(git -C "$DEST" rev-parse --short HEAD)"
