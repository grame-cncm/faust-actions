#!/bin/bash
# Compile one Faust program into a Max external: with faust2max6 on macOS
# (universal $NAME~.mxo), with faust2w64max6 and MinGW on Windows
# ($NAME~.mxe64, x64).
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   MAXSDK   Max SDK c74support directory
#
# Writes $OUT/$NAME-max.zip, holding a $NAME/ folder with the external,
# $NAME.maxpat, ui.js and the sources ($NAME.dsp, plus the files of the
# archive), and $OUT/build.log.

. "$(dirname "$0")/lib.sh"
require_os macos windows

: "${MAXSDK:?}"
# On Windows, a D:/... path: the MinGW compiler, a native program, does not
# read the /d/... paths of Git Bash.
[ "$OS" = windows ] && MAXSDK=$(cygpath -m "$MAXSDK")
[ -d "$MAXSDK/max-includes" ] && [ -d "$MAXSDK/msp-includes" ] \
    || fail "MAXSDK=$MAXSDK does not contain max-includes and msp-includes"

if [ "$OS" = macos ]; then
    # Everything not listed is refused: -native and -opt tune the code for
    # the runner's CPU, options taking a path (-effect, -I, -A, -o...)
    # cannot refer to anything the user sent, -soundfile-dynamic links a
    # library users do not have, -osc links libOSCFaust.a, which the Faust
    # build only produces for the runner's own architecture, and -arch is
    # set by ARCH.
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
    exit 0
fi

# Windows: faust2w64max6 with the runner's MinGW-w64. The script knows -mc
# and -nopost only and passes every other argument to faust (it always
# compiles in double): -midi, -nvoices, -soundfile, -nopatch... would reach
# faust and fail there.
FLAGS=" -mc -nopost -vec -dfs -fun -mcd -lv "
VALUED=" -vs -ftz "
LITERAL=""
check_options

# MinGW-w64: x86_64-w64-mingw32-g++ when installed under that name,
# otherwise a g++ that targets it (the runner's C:\mingw64).
if command -v x86_64-w64-mingw32-g++ > /dev/null; then
    export MINGWPREFIX=x86_64-w64-mingw32-
elif command -v g++ > /dev/null && [ "$(g++ -dumpmachine)" = x86_64-w64-mingw32 ]; then
    export MINGWPREFIX=
else
    fail "no MinGW-w64 g++ targeting x86_64-w64-mingw32 on the PATH"
fi
echo "mingw: $(command -v "${MINGWPREFIX}g++") ($("${MINGWPREFIX}g++" -dumpversion))" >> "$OUT/build.log"

[ -f "$MAXSDK/max-includes/x64/MaxAPI.lib" ] && [ -f "$MAXSDK/msp-includes/x64/MaxAudio.lib" ] \
    || fail "MAXSDK=$MAXSDK lacks max-includes/x64/MaxAPI.lib or msp-includes/x64/MaxAudio.lib"
export MAXSDK

# faust2w64max6 builds natively on Windows since Faust 21a913abf
# (master-dev, 2026-11-04): MAXSDK from faustpath, a working directory not
# named TMP (where the Windows compiler puts its temporary files), a link
# without dllwrap when MinGW has none, and the OSC headers, which faust -i
# reads, installed without the OSC library.
script=$(command -v faust2w64max6) || fail "faust2w64max6 not found"
grep -q 'BUILDDIR=' "$script" \
    || fail "this faust2w64max6 does not build on Windows: use a Faust from master-dev 21a913abf or later (faust-ref)"
[ -f "$(unix_path "$(faust -includedir)")/faust/gui/OSCControler.h" ] \
    || fail "the Faust install lacks faust/gui/OSCControler.h, which faust -i reads: use a Faust from master-dev 21a913abf or later"

prepare_sources
run_logged "$script" ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

[ -f "$NAME~.mxe64" ] || fail "faust2w64max6 did not produce $NAME~.mxe64"
check_binary_archs "$NAME~.mxe64"
# Max loads an external through its exported main
# (the runner's MinGW has the prefixed compiler but an unprefixed objdump)
objdump=$(command -v "${MINGWPREFIX}objdump" || command -v objdump || true)
if [ -n "$objdump" ]; then
    # the name table of the exports: "[   0] main", or with newer
    # binutils "[   0] +base[   1] 0000 main"
    "$objdump" -p "$NAME~.mxe64" \
        | sed -n '/\[Ordinal\/Name Pointer\] Table/,/^[[:space:]]*$/p' \
        | grep -Eq '[[:space:]]main$' \
        || fail "$NAME~.mxe64 does not export main"
    echo "exports: main"
fi
package max
