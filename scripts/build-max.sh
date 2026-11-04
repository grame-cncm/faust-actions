#!/bin/bash
# Compile one Faust program into a Max external with faust2max6.
#
# Environment:
#   DSP      Faust source code (text)
#   NAME     program name, without .dsp
#   OPTIONS  extra faust2max6 options, checked against an allow-list
#   ARCH     universal, arm64 or x86_64
#   MAXSDK   Max SDK c74support directory
#   OUT      output directory; receives $NAME-max.zip and build.log
#
# The zip holds a $NAME/ folder with $NAME~.mxo, $NAME.maxpat, ui.js and
# the source $NAME.dsp.

set -euo pipefail
set -f    # no globbing when OPTIONS is split into words

fail() { echo "::error::$*" >&2; exit 1; }

: "${DSP:?}" "${NAME:?}" "${ARCH:?}" "${MAXSDK:?}" "${OUT:?}"
OPTIONS=${OPTIONS:-}

[[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || fail "invalid name '$NAME': letters, digits and '_' only, not starting with a digit"

case "$ARCH" in
    universal) expected="x86_64 arm64" ;;
    arm64|x86_64) expected="$ARCH" ;;
    *) fail "invalid arch '$ARCH'" ;;
esac

[ -d "$MAXSDK/max-includes" ] && [ -d "$MAXSDK/msp-includes" ] \
    || fail "MAXSDK=$MAXSDK does not contain max-includes and msp-includes"

# Options taking no value, then options taking one number. Everything else
# is refused: -native and -opt tune the code for the runner's CPU, options
# taking a path (-effect, -I, -A, -o...) cannot refer to anything the user
# sent, -soundfile-dynamic links a library users do not have, -osc links
# libOSCFaust.a, which the Faust build only produces for the runner's own
# architecture, and -arch is set by ARCH.
FLAGS=" -mc -midi -soundfile -nopatch -nosrc -nopost -double -vec -dfs -fun -mcd -lv "
VALUED=" -nvoices -us -ds -filter -vs -ftz "
read -r -a opts <<< "$OPTIONS"
i=0
while [ $i -lt ${#opts[@]} ]; do
    o=${opts[$i]}
    if [[ "$FLAGS" == *" $o "* ]]; then
        :
    elif [[ "$VALUED" == *" $o "* ]]; then
        i=$((i + 1))
        [ $i -lt ${#opts[@]} ] && [[ "${opts[$i]}" =~ ^[0-9]+$ ]] \
            || fail "option $o needs a number"
    else
        fail "option '$o' is not allowed"
    fi
    i=$((i + 1))
done

mkdir -p "$OUT/$NAME"
cd "$OUT/$NAME"
printf '%s\n' "$DSP" > "$NAME.dsp"

{
    echo "faust: $(command -v faust)"
    faust --version | head -n 2
    echo "faust2max6 -arch $ARCH ${opts[*]+${opts[*]} }$NAME.dsp"
} > "$OUT/build.log"

status=0
faust2max6 -arch "$ARCH" ${opts[@]+"${opts[@]}"} "$NAME.dsp" >> "$OUT/build.log" 2>&1 || status=$?
cat "$OUT/build.log"
[ $status -eq 0 ] || fail "faust2max6 failed with status $status"

binary="$NAME~.mxo/Contents/MacOS/$NAME~"
[ -f "$binary" ] || fail "faust2max6 did not produce $binary"

archs=$(lipo -archs "$binary")
echo "architectures: $archs"
for a in $expected; do
    [[ " $archs " == *" $a "* ]] || fail "$binary lacks the $a slice (has: $archs)"
done
codesign --verify --verbose "$NAME~.mxo"

cd "$OUT"
rm -f "$NAME-max.zip"
# Without --noextattr, ditto stores the files' extended attributes as ._*
# entries in the zip, which then reappear as stray files on extraction.
ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$NAME-max.zip"
echo "wrote $OUT/$NAME-max.zip"
