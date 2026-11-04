#!/bin/bash
# Build Faust at commit $SHA of grame-cncm/faust and install it in $PREFIX.
# Takes about 3 min 30 on a macos-15 runner.
set -euo pipefail
: "${SHA:?}" "${PREFIX:?}"
[[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::invalid Faust commit '$SHA'"; exit 1; }
src="$RUNNER_TEMP/faust-src"
git init -q "$src"
cd "$src"
git remote add origin https://github.com/grame-cncm/faust
git fetch -q --depth 1 origin "$SHA"
git checkout -q FETCH_HEAD
git submodule update -q --init --recursive --depth 1
make
make install PREFIX="$PREFIX"
