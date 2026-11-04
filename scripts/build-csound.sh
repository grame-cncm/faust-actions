#!/bin/bash
# Compile one Faust program into a Csound opcode with faust2csound.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   CSOUND_HEADERS  directory holding csdl.h and the other Csound headers
#                   (the Headers folder of CsoundLib64.framework on macOS,
#                   /usr/include/csound of libcsound64-dev on Linux)
#
# Writes $OUT/$NAME-csound.zip, holding a $NAME/ folder with $NAME.dylib
# (macOS) or $NAME.so (Linux)
# and the sources, and $OUT/build.log.

. "$(dirname "$0")/lib.sh"

require_os macos linux
: "${CSOUND_HEADERS:?}"
[ -f "$CSOUND_HEADERS/csdl.h" ] || fail "CSOUND_HEADERS=$CSOUND_HEADERS does not contain csdl.h"

# Everything not listed is refused: -arch32 and -arch64 are meaningless on
# macOS. faust2csound always compiles with -double, as Csound's MYFLT is.
FLAGS=" -vec -dfs -fun -mcd -lv "
VALUED=" -vs -ftz "
LITERAL=""
FILEARGS=""
check_options

prepare_sources

# faust2csound has no option for the architectures, but appends its own
# flags to CXXFLAGS and compiles and links in one clang command, which
# takes several -arch flags. Its include path for the headers is the
# installed framework; CXXFLAGS adds this one first.
case "$OS:$ARCH" in
    macos:universal) archflags="-arch x86_64 -arch arm64" ;;
    macos:*) archflags="-arch $ARCH" ;;
    *) archflags="" ;;
esac
export CXXFLAGS="-I$CSOUND_HEADERS $archflags"
echo "csound headers: $CSOUND_HEADERS, CXXFLAGS=$CXXFLAGS" >> "$OUT/build.log"
run_logged faust2csound ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

[ "$OS" = macos ] && opcode="$NAME.dylib" || opcode="$NAME.so"
[ -f "$opcode" ] || fail "faust2csound did not produce $opcode"
adhoc_sign "$opcode"
check_bundle_archs "$opcode"
verify_signature "$opcode"

package csound
