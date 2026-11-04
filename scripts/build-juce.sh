#!/bin/bash
# Compile one Faust program into JUCE plugins (AU, VST3 and Standalone)
# with faust2juce and the CMake project it writes.
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   JUCEDIR  a JUCE 7 or 8 checkout
#
# Writes $OUT/$NAME-juce.zip, holding a $NAME/ folder with $NAME.component
# (AU), $NAME.vst3, $NAME.app (Standalone) and the sources, and
# $OUT/build.log.

. "$(dirname "$0")/lib.sh"

: "${JUCEDIR:?}"
[ -f "$JUCEDIR/CMakeLists.txt" ] && [ -d "$JUCEDIR/modules/juce_audio_processors" ] \
    || fail "JUCEDIR=$JUCEDIR is not a JUCE checkout"

# Everything not listed is refused: -standalone and -llvm produce a .jucer
# project only, which needs Projucer (the plugin build has a Standalone
# format anyway); -magic needs the foleys_gui_magic module; -vst2sdkdir
# and -jucemodulesdir take paths on the user's machine; -soundfile is not
# tested with the CMake build yet. -osc uses JUCE's own OSC module, not
# libOSCFaust. -effect and -presets take a file of the archive (or auto).
FLAGS=" -midi -osc -jsynth -disable-splash-screen -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -vs -ftz "
LITERAL=""
FILEARGS=" -effect -presets "
check_options

prepare_sources
run_logged faust2juce ${OPTS[@]+"${OPTS[@]}"} "$NAME.dsp"
[ -f "$NAME/CMakeLists.txt" ] || fail "faust2juce did not write $NAME/CMakeLists.txt"

# The project and the build stay outside $OUT/$NAME, which is what the zip
# holds: the CMake project points to the runner's Faust include directory
# and could not be rebuilt elsewhere.
project="$OUT/.project"
build="$OUT/.build"
mv "$NAME" "$project"

case "$ARCH" in
    universal) osx_archs="arm64;x86_64" ;;
    *) osx_archs="$ARCH" ;;
esac

# step <command...>: run a build step with its output in build.log; on
# failure, print the end of the log, which holds the compiler error
step() {
    echo "$*" >> "$OUT/build.log"
    local status=0
    env -u DSP -u ARCHIVE -u DSP_FILE -u OPTIONS -u NAME -u ARCH -u OUT \
        "$@" >> "$OUT/build.log" 2>&1 || status=$?
    if [ $status -ne 0 ]; then
        tail -n 60 "$OUT/build.log"
        fail "$1 failed with status $status"
    fi
}

echo "juce: $JUCEDIR ($(git -C "$JUCEDIR" describe --tags 2> /dev/null || echo unknown)), CMAKE_OSX_ARCHITECTURES=$osx_archs" >> "$OUT/build.log"
step cmake -S "$project" -B "$build" -DJUCE_DIR="$JUCEDIR" \
    -DCMAKE_BUILD_TYPE=Release "-DCMAKE_OSX_ARCHITECTURES=$osx_archs"
step cmake --build "$build" --config Release -j "$(sysctl -n hw.ncpu)"

# JUCE leaves the bundles with the linker's signature of their binary
# only: sign each bundle (ad hoc), then check its slices and signature.
artefacts="$build/${NAME}_artefacts/Release"
n=0
for bundle in "AU/$NAME.component" "VST3/$NAME.vst3" "Standalone/$NAME.app"; do
    [ -d "$artefacts/$bundle" ] || fail "the build did not produce $bundle"
    dest="$OUT/$NAME/$(basename "$bundle")"
    ditto "$artefacts/$bundle" "$dest"
    codesign --sign - --force --deep "$dest"
    check_bundle_archs "$dest"
    codesign --verify --deep --strict --verbose "$dest"
    n=$((n + 1))
done
echo "bundles: $n (AU, VST3, Standalone)"

package juce
