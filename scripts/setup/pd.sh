#!/bin/bash
# Fetch m_pd.h of Pure Data $PD_VERSION into $DEST. Externals need nothing
# else: they are linked with -undefined suppress.
set -euo pipefail
: "${PD_VERSION:?}" "${DEST:?}"
[[ "$PD_VERSION" =~ ^[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo "::error::invalid Pure Data version '$PD_VERSION'"; exit 1; }
mkdir -p "$DEST"
curl -sSfL -o "$DEST/m_pd.h" "https://raw.githubusercontent.com/pure-data/pure-data/$PD_VERSION/src/m_pd.h"
grep -m1 -E 'define PD_(MAJOR|MINOR)_VERSION' "$DEST/m_pd.h"
