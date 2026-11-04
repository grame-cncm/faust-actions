#!/bin/bash
# Build Faust at commit $SHA of grame-cncm/faust with CMake and Visual
# Studio (build/README-MSVC.md), and install it in $PREFIX: faust.exe, the
# architecture files, the libraries and the faust2xxx scripts, which run
# in Git Bash. The Faust OSC and HTTP libraries are left out: no Windows
# target uses them (JUCE has its own OSC module), and the HTTP one needs
# libmicrohttpd.
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
# The -D options come after the -C ones, whose settings they override.
cmake -S build -B build/msvc -A x64 \
    -C build/backends/regular.cmake -C build/targets/regular.cmake \
    -DINCLUDE_OSC=OFF -DINCLUDE_HTTP=OFF \
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
cmake --build build/msvc --config Release -j "${NUMBER_OF_PROCESSORS:-2}"
cmake --install build/msvc --config Release --prefix "$PREFIX"
