#!/bin/bash
# Compile one Faust program into a Max external: with faust2max6 on macOS
# (universal $NAME~.mxo), with faust2w64max6 and MinGW on Windows
# ($NAME~.mxe64, x64).
#
# Environment: DSP or ARCHIVE, NAME, OPTIONS, ARCH, OUT (see lib.sh), and
#   MAXSDK        Max SDK c74support directory
#   FAUST_COMMIT  the commit Faust was built from (Windows: see below)
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

# Windows. faust2w64max6 knows -mc and -nopost only and passes every other
# argument to faust (it always compiles in double): -midi, -nvoices,
# -soundfile, -nopatch... would reach faust and fail there.
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

# faust2w64max6 links the external with dllwrap, which recent MinGW
# distributions (the runner's among them) no longer ship. Without it, a
# stand-in on the PATH does the same link with the compiler driver:
# -shared, the .def file giving the exported symbol (main), and the other
# arguments as they are (--target, which only dllwrap reads, is dropped).
mkdir -p "$OUT/.bin"
export PATH="$OUT/.bin:$PATH"
if ! command -v "${MINGWPREFIX}dllwrap" > /dev/null; then
    cat > "$OUT/.bin/${MINGWPREFIX}dllwrap" <<'SHIM'
#!/bin/bash
driver=
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --target=*) ;;
        --driver-name) driver=$2; shift ;;
        --def) args+=("$2"); shift ;;
        *) args+=("$1") ;;
    esac
    shift
done
exec "${driver:?dllwrap stand-in: no --driver-name}" -shared "${args[@]}"
SHIM
    chmod +x "$OUT/.bin/${MINGWPREFIX}dllwrap"
    echo "dllwrap: not found, using a stand-in that links with ${MINGWPREFIX}g++ -shared" >> "$OUT/build.log"
fi

[ -f "$MAXSDK/max-includes/x64/MaxAPI.lib" ] && [ -f "$MAXSDK/msp-includes/x64/MaxAudio.lib" ] \
    || fail "MAXSDK=$MAXSDK lacks max-includes/x64/MaxAPI.lib or msp-includes/x64/MaxAudio.lib"
export MAXSDK

# Run a copy of faust2w64max6 with two fixes, each applied only when the
# script still needs it:
# - older versions set MAXSDK to /usr/local/include/c74support whatever the
#   environment says: keep the value of faustpath (MAXSDK when set);
# - it names its working directory TMP, a relative path, while TMP is also
#   the variable in which the Windows compiler creates its temporary files:
#   after its cd, g++ fails with "Cannot create temporary file". Rename it.
script=$(command -v faust2w64max6) || fail "faust2w64max6 not found"
sed -e 's|^MAXSDK=/usr/local/include/c74support.*|[ -n "$MAXSDK" ] \|\| MAXSDK=/usr/local/include/c74support|' \
    -e 's/\([^A-Za-z_]\)TMP=/\1FAUST_TMP=/' -e 's/\$TMP/$FAUST_TMP/g' \
    "$script" > "$OUT/.bin/faust2w64max6"
chmod +x "$OUT/.bin/faust2w64max6"
script="$OUT/.bin/faust2w64max6"

# faust2w64max6 runs faust -i, which inlines every header the architecture
# names, those of OSCUI.h included. Faust's CMake installs them with the
# OSC library only, which the Windows build of this action leaves out:
# when they are missing, fetch them from the sources of the same commit.
inc=$(unix_path "$(faust -includedir)")/faust
if [ ! -f "$inc/gui/OSCControler.h" ]; then
    : "${FAUST_COMMIT:?FAUST_COMMIT is needed to fetch the OSC headers}"
    src="https://raw.githubusercontent.com/grame-cncm/faust/$FAUST_COMMIT/architecture/osclib/faust/faust"
    mkdir -p "$inc/osc"
    for h in OSCControler.h OSCIO.h; do
        curl -fsSL "$src/$h" -o "$inc/gui/$h" || fail "could not fetch $h"
    done
    for h in FaustFactory.h FaustNode.h Message.h MessageDriven.h MessageProcessor.h RootNode.h smartpointer.h; do
        curl -fsSL "$src/osc/$h" -o "$inc/osc/$h" || fail "could not fetch osc/$h"
    done
    echo "OSC headers: fetched from grame-cncm/faust@$FAUST_COMMIT into $inc" >> "$OUT/build.log"
fi

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
