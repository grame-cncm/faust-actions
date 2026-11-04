#!/bin/bash
# Compile one Faust program into a Max external with faust2max6.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   MAXSDK   Max SDK c74support directory
#
# Writes $OUT/$NAME-max.zip, holding a $NAME/ folder with $NAME~.mxo,
# $NAME.maxpat, ui.js and the sources ($NAME.dsp, plus the files of the
# archive), and $OUT/build.log.

. "$(dirname "$0")/lib.sh"
require_os macos

: "${MAXSDK:?}"
[ -d "$MAXSDK/max-includes" ] && [ -d "$MAXSDK/msp-includes" ] \
    || fail "MAXSDK=$MAXSDK does not contain max-includes and msp-includes"

# Everything not listed is refused: -native and -opt tune the code for the
# runner's CPU, options taking a path (-effect, -I, -A, -o...) cannot refer
# to anything the user sent, -soundfile-dynamic links a library users do
# not have, -osc links libOSCFaust.a, which the Faust build only produces
# for the runner's own architecture, and -arch is set by ARCH.
FLAGS=" -mc -midi -soundfile -nopatch -nosrc -nopost -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -us -ds -filter -vs -ftz "
LITERAL=""
check_options

prepare_sources
run_logged faust2max6 -arch "$ARCH" ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

[ -f "$NAME~.mxo/Contents/MacOS/$NAME~" ] || fail "faust2max6 did not produce $NAME~.mxo"
check_bundle_archs "$NAME~.mxo"
codesign --verify --verbose "$NAME~.mxo"

package max
