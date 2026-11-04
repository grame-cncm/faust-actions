#!/bin/bash
# Fetch the include/ directory of SuperCollider $SC_VERSION into
# $DEST/include, by a sparse checkout.
set -euo pipefail
: "${SC_VERSION:?}" "${DEST:?}"
[[ "$SC_VERSION" =~ ^Version-[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "::error::invalid SuperCollider version '$SC_VERSION'"; exit 1; }
git clone -q --depth 1 --branch "$SC_VERSION" --filter=blob:none --sparse https://github.com/supercollider/supercollider "$DEST"
git -C "$DEST" sparse-checkout set include
ls "$DEST/include"
