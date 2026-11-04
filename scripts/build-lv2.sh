#!/bin/bash
# Compile one Faust program into an LV2 plugin with faust2lv2, on Linux.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh).
#   The LV2 headers (lv2-dev) and Boost (libboost-dev, for
#   boost/circular_buffer.hpp) must be installed.
#
# Writes $OUT/$NAME-lv2.zip, holding a $NAME/ folder with the $NAME.lv2
# bundle (plugin library and .ttl files) and the sources, and
# $OUT/build.log.

. "$(dirname "$0")/lib.sh"
require_os linux

# Everything not listed is refused: -gui, -qt4 and -qt5 build a Qt GUI,
# not set up yet; -osx is for macOS; -keep and -style only matter with
# a GUI or for debugging. faust2lv2 has its own -nvoices.
FLAGS=" -dyn-manifest -nometa -nomidicc -notuning -novoicectrls -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -vs -ftz "
LITERAL=""
FILEARGS=""
check_options

prepare_sources
# faust2lv2 looks for lv2.cpp and lv2ui.cpp in FAUSTLIB and for the Faust
# headers in FAUSTINC, by default in /usr/local, not where Faust is.
export FAUSTLIB FAUSTINC
FAUSTLIB=$(faust -archdir)
FAUSTINC=$(faust -includedir)
run_logged faust2lv2 ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

bundle="$NAME.lv2"
[ -d "$bundle" ] && [ -f "$bundle/manifest.ttl" ] || fail "faust2lv2 did not produce $bundle"
check_bundle_archs "$bundle"
echo "bundle: $bundle ($(ls "$bundle" | tr '\n' ' '))"

package lv2
