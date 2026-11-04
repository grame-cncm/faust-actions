#!/bin/bash
# Compile one Faust program into a Pure Data external with faust2puredata.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   PUREDATA_MACSDK  directory holding m_pd.h
#
# Writes $OUT/$NAME-puredata.zip, holding a $NAME/ folder with
# $NAME~.pd_darwin and the sources, and $OUT/build.log. The .pd patch that
# faust2pd writes is not produced: faust2pd is not installed on the runner.

. "$(dirname "$0")/lib.sh"

: "${PUREDATA_MACSDK:?}"
[ -f "$PUREDATA_MACSDK/m_pd.h" ] || fail "PUREDATA_MACSDK=$PUREDATA_MACSDK does not contain m_pd.h"

# Everything not listed is refused: -arch32 and -arch64 are meaningless on
# macOS, -tosource returns no external.
FLAGS=" -poly -newio -double -vec -dfs -fun -mcd -lv "
VALUED=" -vs -ftz "
LITERAL=""
FILEARGS=""
check_options

prepare_sources
# On an arm machine, faust2puredata always builds both architectures.
run_logged faust2puredata ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

external="$NAME~.pd_darwin"
[ -f "$external" ] || fail "faust2puredata did not produce $external"
thin_to_arch "$external"
check_bundle_archs "$external"
codesign --verify --strict --verbose "$external"

package puredata
