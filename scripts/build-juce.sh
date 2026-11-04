#!/bin/bash
# Compile one Faust program into JUCE plugins with faust2juce and the CMake
# project it writes: AU, VST3 and Standalone on macOS, VST3 and Standalone
# on Linux and Windows (JUCE builds AU on Apple platforms only).
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   JUCEDIR  a JUCE 7 or 8 checkout
#
# Writes $OUT/$NAME-juce.zip, holding a $NAME/ folder with the plugins
# ($NAME.component, $NAME.vst3) and the Standalone ($NAME.app on macOS,
# $NAME on Linux, $NAME.exe on Windows) and the sources, and $OUT/build.log.

. "$(dirname "$0")/lib.sh"

: "${JUCEDIR:?}"
JUCEDIR=$(unix_path "$JUCEDIR")
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

# faust2juce writes the Faust include directory into the CMake project with
# sed; on Windows that path has backslashes, which sed turns into escape
# sequences (\a, \f...). Rewrite the line that follows JuceLibraryCode in
# target_include_directories with a D:/... path, which CMake reads.
if [ "$OS" = windows ]; then
    faustinc=$(cygpath -m "$(faust -includedir)")
    awk -v inc="$faustinc" '
        fix { print "    \"" inc "\")"; fix = 0; next }
        /CMAKE_CURRENT_SOURCE_DIR}\/JuceLibraryCode"$/ { fix = 1 }
        { print }' "$project/CMakeLists.txt" > "$project/CMakeLists.fixed"
    mv "$project/CMakeLists.fixed" "$project/CMakeLists.txt"
    grep -qF "\"$faustinc\")" "$project/CMakeLists.txt" \
        || fail "could not set the Faust include directory in the CMake project"
fi

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

case "$OS" in
    macos)
        case "$ARCH" in
            universal) osx_archs="arm64;x86_64" ;;
            *) osx_archs="$ARCH" ;;
        esac
        configure_flags=("-DCMAKE_OSX_ARCHITECTURES=$osx_archs")
        jobs=$(sysctl -n hw.ncpu)
        bundles=("AU/$NAME.component" "VST3/$NAME.vst3" "Standalone/$NAME.app")
        ;;
    linux)
        configure_flags=()
        jobs=$(nproc)
        bundles=("VST3/$NAME.vst3" "Standalone/$NAME")
        ;;
    windows)
        configure_flags=(-A x64)
        jobs=${NUMBER_OF_PROCESSORS:-2}
        bundles=("VST3/$NAME.vst3" "Standalone/$NAME.exe")
        ;;
esac

echo "juce: $JUCEDIR ($(git -C "$JUCEDIR" describe --tags 2> /dev/null || echo unknown)), $OS $ARCH ${configure_flags[*]+${configure_flags[*]}}" >> "$OUT/build.log"
step cmake -S "$project" -B "$build" -DJUCE_DIR="$JUCEDIR" \
    -DCMAKE_BUILD_TYPE=Release ${configure_flags[@]+"${configure_flags[@]}"}
step cmake --build "$build" --config Release -j "$jobs"

# On macOS, JUCE leaves the bundles with the linker's signature of their
# binary only: sign each bundle (ad hoc), then check its slices and
# signature. Elsewhere, check the architecture of the binaries.
artefacts="$build/${NAME}_artefacts/Release"
n=0
for bundle in "${bundles[@]}"; do
    [ -e "$artefacts/$bundle" ] || fail "the build did not produce $bundle"
    dest="$OUT/$NAME/$(basename "$bundle")"
    if [ "$OS" = macos ]; then
        ditto "$artefacts/$bundle" "$dest"
    else
        cp -R "$artefacts/$bundle" "$dest"
    fi
    adhoc_sign "$dest" --deep
    check_bundle_archs "$dest"
    verify_signature "$dest" --deep
    n=$((n + 1))
done
echo "bundles: $n (${bundles[*]})"

package juce
