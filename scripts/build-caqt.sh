#!/bin/bash
# Compile one Faust program into a CoreAudio + Qt application with
# faust2caqt.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   QTDIR    Qt prefix holding bin/qmake and bin/macdeployqt; for a
#            universal application, Qt itself must be universal (the Qt
#            online installer and aqtinstall provide universal builds,
#            Homebrew's Qt is arm64 only)
#
# Writes $OUT/$NAME-caqt.zip, holding a $NAME/ folder with $NAME.app (Qt
# frameworks and plugins included by macdeployqt) and the sources, and
# $OUT/build.log.

. "$(dirname "$0")/lib.sh"
require_os macos

: "${QTDIR:?}"
[ -x "$QTDIR/bin/qmake" ] && [ -x "$QTDIR/bin/macdeployqt" ] \
    || fail "QTDIR=$QTDIR does not contain bin/qmake and bin/macdeployqt"
export PATH="$QTDIR/bin:$PATH"

# Everything not listed is refused: -opt runs faustbench-llvm and tunes the
# code for the runner's CPU; -httpd, -qrcode and -osc link libHTTPDFaust.a,
# libmicrohttpd or libOSCFaust.a, and -soundfile and -resample link
# Homebrew's libsndfile and libsamplerate, all of them built for the
# runner's architecture only and, for Homebrew, as shared libraries users
# do not have; -I, -effect <file> and -preset <dir> take paths;
# -nodeploy would leave the Qt frameworks out of the application.
FLAGS=" -midi -me -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -vs -ftz "
LITERAL=" -effect=auto -preset=auto "
check_options

prepare_sources

# Recent faust2caqt versions take -arch. Older ones have no option to
# choose the architectures: qmake looks for a .qmake.conf in the project
# directory and its parents, and faust2caqt creates its project in a
# temporary directory under the current one, so this file then sets the
# architectures of the whole build.
faust2caqt -help > "$OUT/.caqt-help" 2>&1 || true
if grep -q -- '-arch auto' "$OUT/.caqt-help"; then
    echo "qt: $QTDIR (Qt $(qmake -query QT_VERSION)), faust2caqt -arch $ARCH" >> "$OUT/build.log"
    run_logged faust2caqt -arch "$ARCH" ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"
else
    case "$ARCH" in
        universal) qarchs="x86_64 arm64" ;;
        *) qarchs="$ARCH" ;;
    esac
    printf 'QMAKE_APPLE_DEVICE_ARCHS = %s\n' "$qarchs" > .qmake.conf
    echo "qt: $QTDIR (Qt $(qmake -query QT_VERSION)), faust2caqt without -arch, .qmake.conf with QMAKE_APPLE_DEVICE_ARCHS = $qarchs" >> "$OUT/build.log"
    run_logged faust2caqt ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"
    # qmake writes its .qmake.stash next to the .qmake.conf it found
    rm -f .qmake.conf .qmake.stash
fi
rm -f "$OUT/.caqt-help"

[ -d "$NAME.app" ] || fail "faust2caqt did not produce $NAME.app"
check_bundle_archs "$NAME.app"
codesign --verify --deep --strict --verbose "$NAME.app"

package caqt
