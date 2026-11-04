#!/bin/bash
# Compile one Faust program into a JACK + Qt application with faust2jaqt,
# for Apple Silicon only.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   QTDIR    Qt prefix holding bin/qmake and bin/macdeployqt
#   JACK must be visible to pkg-config (Homebrew's jack on the runner).
#
# Writes $OUT/$NAME-jaqt.zip, holding a $NAME/ folder with $NAME.app (Qt
# frameworks included, libjack not) and the sources, and $OUT/build.log.
# The application needs JACK installed on the user's machine, in
# /usr/local/lib (JackOSX installer) or /opt/homebrew/lib (Homebrew).

. "$(dirname "$0")/lib.sh"
require_os macos

# Arm64 only: faust2jaqt builds for the machine it runs on, and Homebrew's
# libjack, which it links, is arm64 only.
[ "$ARCH" = arm64 ] || fail "jack-qt applications are built for arm64 only (arch=$ARCH)"

: "${QTDIR:?}"
[ -x "$QTDIR/bin/qmake" ] && [ -x "$QTDIR/bin/macdeployqt" ] \
    || fail "QTDIR=$QTDIR does not contain bin/qmake and bin/macdeployqt"
export PATH="$QTDIR/bin:$PATH"
pkg-config --exists jack || fail "pkg-config does not find jack"

# Everything not listed is refused: -httpd, -qrcode, -soundfile and
# -resample link Homebrew's libmicrohttpd, libsndfile and libsamplerate,
# not tested yet; -effect <file> and -preset <dir> take paths. -osc links
# libOSCFaust.a, which the Faust build produces for arm64 on the runner.
FLAGS=" -midi -osc -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -vs -ftz "
LITERAL=" -effect=auto -preset=auto "
FILEARGS=""
check_options

prepare_sources
# faust2jaqt passes `pkg-config --cflags --libs jack` to qmake as LIBS, so
# the include path only reaches the linker; it appends its own flags to
# CXXFLAGS, which qmake gets as QMAKE_CXXFLAGS. Needed when JACK is not in
# a default include directory (Homebrew's /opt/homebrew/include).
export CXXFLAGS="$(pkg-config --cflags jack)"
# Likewise, -osc links -lOSCFaust without the path of Faust's libraries;
# faust2jaqt appends to LFLAGS, which qmake gets as QMAKE_LFLAGS. Needed
# when Faust is not installed in a default library directory.
export LFLAGS="-L$(faust -libdir)"
echo "qt: $QTDIR (Qt $(qmake -query QT_VERSION)), jack $(pkg-config --modversion jack) ($(pkg-config --variable=libdir jack))" >> "$OUT/build.log"
# -deploy (not listed by -help) runs macdeployqt; without it the
# application would load Qt from the runner's installation.
run_logged faust2jaqt -deploy ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"

app="$NAME.app"
binary="$app/Contents/MacOS/$NAME"
[ -f "$binary" ] || fail "faust2jaqt did not produce $app"

# macdeployqt copies libjack into the application. The JACK client library
# must match the user's JACK server, so load the installed one instead:
# @rpath/libjack.0.dylib, searched in the Frameworks folder (where it no
# longer is), then where the JackOSX installer and Homebrew put it.
bundled=$(otool -L "$binary" | awk '/libjack/ { print $1; exit }')
[ -n "$bundled" ] || fail "$binary does not link libjack"
if [[ "$bundled" == @executable_path/* ]]; then
    install_name_tool -change "$bundled" "@rpath/libjack.0.dylib" "$binary"
    install_name_tool -add_rpath /usr/local/lib "$binary"
    install_name_tool -add_rpath /opt/homebrew/lib "$binary"
    rm -f "$app/Contents/Frameworks/$(basename "$bundled")"
fi
if find "$app" -iname '*libjack*' | grep -q .; then
    fail "libjack is still in $app: $(find "$app" -iname '*libjack*' | tr '\n' ' ')"
fi
echo "libjack: $(otool -L "$binary" | awk '/libjack/ { print $1; exit }'), rpaths: $(otool -l "$binary" | awk '/LC_RPATH/ { getline; getline; print $2 }' | tr '\n' ' ')" >> "$OUT/build.log"
codesign --sign - --force --deep "$app"

check_bundle_archs "$app"
codesign --verify --deep --strict --verbose "$app"

package jaqt
