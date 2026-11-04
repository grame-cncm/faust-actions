#!/bin/bash
# Compile one Faust program into a SuperCollider UGen with
# faust2supercollider.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   SUPERCOLLIDER_HEADERS  the include/ directory of the SuperCollider
#                          sources (plugin_interface, common, server); on
#                          Linux, /usr/include/SuperCollider of the
#                          supercollider-dev package
#
# Writes $OUT/$NAME-supercollider.zip, holding a $NAME/ folder with
# $NAME.scx on macOS or $NAME.so on Linux (plus ${NAME}_supernova.scx or
# .so with -sn), the $NAME.sc class file and the sources, and
# $OUT/build.log.

. "$(dirname "$0")/lib.sh"

require_os macos linux
: "${SUPERCOLLIDER_HEADERS:?}"
[ -d "$SUPERCOLLIDER_HEADERS/plugin_interface" ] \
    || fail "SUPERCOLLIDER_HEADERS=$SUPERCOLLIDER_HEADERS does not contain plugin_interface"
command -v ruby > /dev/null || fail "ruby is needed by faust2sc, which writes the .sc class file"

# Everything not listed is refused: -soundfile links Homebrew's libsndfile
# (arm64 only), -d and -dm write to /dev/tty, -universal is set here.
FLAGS=" -noprefix -sn -supernova -sd -synthdef -ks -double -vec -dfs -fun -mcd -lv "
VALUED=" -vs -ftz "
LITERAL=""
FILEARGS=""
check_options

prepare_sources
if [ "$OS" = macos ]; then
    ext=scx
    run_logged faust2supercollider -universal ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"
else
    ext=so
    run_logged faust2supercollider ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"
fi

[ -f "$NAME.sc" ] || fail "faust2supercollider did not produce $NAME.sc"
n=0
for ugen in "$NAME.$ext" "${NAME}_supernova.$ext"; do
    [ -f "$ugen" ] || continue
    thin_to_arch "$ugen"
    check_bundle_archs "$ugen"
    verify_signature "$ugen"
    n=$((n + 1))
done
[ $n -gt 0 ] || fail "faust2supercollider did not produce $NAME.$ext"

package supercollider
