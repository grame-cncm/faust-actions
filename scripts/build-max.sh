#!/bin/bash
# Compile one Faust program into a Max external with faust2max6.
#
# Environment:
#   DSP      Faust source code (text), or
#   ARCHIVE  base64 of a tar.gz holding $NAME.dsp and the files it imports
#            (.lib, other .dsp, soundfiles), without directories
#   NAME     program name, without .dsp
#   OPTIONS  extra faust2max6 options, checked against an allow-list
#   ARCH     universal, arm64 or x86_64
#   MAXSDK   Max SDK c74support directory
#   OUT      output directory; receives $NAME-max.zip and build.log
#
# The zip holds a $NAME/ folder with $NAME~.mxo, $NAME.maxpat, ui.js and
# the sources ($NAME.dsp, plus the files of the archive).

set -euo pipefail
set -f    # no globbing when OPTIONS is split into words

: "${NAME:?}" "${ARCH:?}" "${MAXSDK:?}" "${OUT:?}"
DSP=${DSP:-}
ARCHIVE=${ARCHIVE:-}
OPTIONS=${OPTIONS:-}

# build.log is the artifact a client reads when the run fails, so every
# refusal goes there as well as to the Actions annotations.
mkdir -p "$OUT"
: > "$OUT/build.log"
fail() { echo "ERROR: $*" >> "$OUT/build.log"; echo "::error::$*" >&2; exit 1; }

if [ -n "$DSP" ] && [ -n "$ARCHIVE" ]; then
    fail "give either dsp or archive, not both"
elif [ -z "$DSP" ] && [ -z "$ARCHIVE" ]; then
    fail "give dsp or archive"
fi

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

# Unpack ARCHIVE into the current directory. Everything is checked before
# anything is extracted: the archive must be flat and hold only regular
# files with plain names and known extensions, so that no entry can land
# outside the build directory or be anything but source.
MAX_TAR_SIZE=600000    # faustservice extracts at most 500 KB
unpack_archive() {
    local work="$OUT/.archive" size names name n_entries n_regular
    mkdir -p "$work"
    printf '%s' "$ARCHIVE" | base64 -d > "$work/in.tgz" 2> /dev/null \
        || fail "archive is not valid base64"
    # Status 2 is gzip's warning for trailing bytes: bsdtar (macOS) pads
    # `tar -czf -` output with zeros to its block size when writing to a pipe.
    local gz=0
    gzip -t "$work/in.tgz" 2> /dev/null || gz=$?
    [ $gz -eq 0 ] || [ $gz -eq 2 ] || fail "archive is not a gzip file (expected tar.gz)"
    # Decompress one byte more than the limit, so an oversized archive (or a
    # compression bomb) is detected without being decompressed in full.
    { gzip -dc "$work/in.tgz" || true; } | head -c $((MAX_TAR_SIZE + 1)) > "$work/in.tar"
    size=$(wc -c < "$work/in.tar" | tr -d ' ')
    [ "$size" -le $MAX_TAR_SIZE ] || fail "archive is larger than $MAX_TAR_SIZE bytes once decompressed"
    names=$(tar -tf "$work/in.tar" 2> /dev/null) || fail "archive is not a tar.gz"
    [ -n "$names" ] || fail "archive is empty"

    while IFS= read -r name; do
        case "$name" in
            */*) fail "archive entry '$name' is in a directory: pack the files flat (tar -cf - prog.dsp mylib.lib | gzip -9 | base64)" ;;
        esac
        [[ "$name" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] \
            || fail "archive entry '$name': letters, digits, '.', '_' and '-' only, not starting with '.'"
        case "${name##*.}" in
            dsp|lib|wav|aif|aiff|flac|ogg|mp3) ;;
            *) fail "archive entry '$name': only .dsp, .lib and soundfiles (.wav .aif .aiff .flac .ogg .mp3) are accepted" ;;
        esac
    done <<< "$names"

    # tar -tv starts each line with the entry type: '-' for a regular file
    n_entries=$(printf '%s\n' "$names" | wc -l | tr -d ' ')
    n_regular=$(tar -tvf "$work/in.tar" | cut -c1 | grep -c '^-' || true)
    [ "$n_entries" -eq "$n_regular" ] \
        || fail "archive holds entries that are not regular files (links, directories...)"
    printf '%s\n' "$names" | grep -Fqx "$NAME.dsp" \
        || fail "archive does not contain $NAME.dsp (it holds: $(echo $names))"

    # Restore no metadata. The macOS tar stores extended attributes in pax
    # headers or in AppleDouble ._* entries; it hides the ._* entries from
    # the listing above and, when extracting, turns them into attributes of
    # the matching file unless all of these options are given.
    tar --no-mac-metadata --no-xattrs --no-acls --no-fflags -xf "$work/in.tar"
    rm -rf "$work"
    echo "archive: $(echo $names)" >> "$OUT/build.log"
}

mkdir -p "$OUT/$NAME"
cd "$OUT/$NAME"
if [ -n "$DSP" ]; then
    printf '%s\n' "$DSP" > "$NAME.dsp"
else
    unpack_archive
fi

{
    echo "faust: $(command -v faust)"
    faust --version | head -n 2
    echo "faust2max6 -arch $ARCH ${opts[*]+${opts[*]} }$NAME.dsp"
} >> "$OUT/build.log"

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
