# Shared part of the build-*.sh scripts: input checks, sources, logging,
# architecture checks and packaging. Sourced, not run.
#
# Environment read here, the sources first, exactly one of:
#   DSP_FILE a .dsp file; the files next to it with the extensions accepted
#            in archives (.lib, .dsp, .json, soundfiles) come with it
#   DSP      Faust source code (text)
#   ARCHIVE  base64 of a tar.gz holding $NAME.dsp and the files it imports
#            (.lib, other .dsp, soundfiles), without directories
#   With FAUSTOSX_FROM_EVENT=1, DSP and ARCHIVE are the dsp and archive
#   inputs of the workflow_dispatch event in $GITHUB_EVENT_PATH instead of
#   environment variables (see below).
# then:
#   NAME     program name, without .dsp (default with DSP_FILE: its name)
#   OPTIONS  extra options for the faust2xxx script, checked by check_options
#   ARCH     universal, arm64 or x86_64
#   OUT      output directory; receives the zip and build.log

set -euo pipefail
set -f    # no globbing when OPTIONS is split into words

: "${ARCH:?}" "${OUT:?}"
DSP=${DSP:-}
ARCHIVE=${ARCHIVE:-}
DSP_FILE=${DSP_FILE:-}
OPTIONS=${OPTIONS:-}
NAME=${NAME:-}
if [ -z "$NAME" ] && [ -n "$DSP_FILE" ]; then
    NAME=$(basename "$DSP_FILE" .dsp)
fi
: "${NAME:?}"

# build.log is the artifact a client reads when the run fails, so every
# refusal goes there as well as to the Actions annotations.
mkdir -p "$OUT"
: > "$OUT/build.log"
fail() { echo "ERROR: $*" >> "$OUT/build.log"; echo "::error::$*" >&2; exit 1; }

# The Actions log prints the environment of each step in its header, which
# would publish the user's source on a public repository. The workflows of
# this repository therefore do not pass dsp and archive in the environment:
# with FAUSTOSX_FROM_EVENT=1 they are read from the event payload, which
# the log does not show.
event_input() {
    if command -v jq > /dev/null; then
        jq -r --arg k "$1" '.inputs[$k] // ""' "$GITHUB_EVENT_PATH"
    else
        python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("inputs", {}).get(sys.argv[2]) or "")' \
            "$GITHUB_EVENT_PATH" "$1"
    fi
}
if [ "${FAUSTOSX_FROM_EVENT:-}" = 1 ]; then
    [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ] \
        || fail "FAUSTOSX_FROM_EVENT=1 needs the event payload in GITHUB_EVENT_PATH"
    [ -z "$DSP$ARCHIVE$DSP_FILE" ] || fail "FAUSTOSX_FROM_EVENT=1 takes the sources from the event only"
    DSP=$(event_input dsp) || fail "cannot read the dsp input from $GITHUB_EVENT_PATH"
    ARCHIVE=$(event_input archive) || fail "cannot read the archive input from $GITHUB_EVENT_PATH"
fi

n_sources=0
for s in "$DSP" "$ARCHIVE" "$DSP_FILE"; do
    [ -n "$s" ] && n_sources=$((n_sources + 1))
done
[ $n_sources -eq 1 ] || fail "give exactly one of dsp, archive and a .dsp file ($n_sources given)"
if [ -n "$DSP_FILE" ]; then
    [ -f "$DSP_FILE" ] || fail "$DSP_FILE is not a file"
    [[ "$DSP_FILE" == *.dsp ]] || fail "$DSP_FILE is not a .dsp file"
    DSP_FILE=$(cd "$(dirname "$DSP_FILE")" && pwd)/$(basename "$DSP_FILE")
fi

[[ "$NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || fail "invalid name '$NAME': letters, digits and '_' only, not starting with a digit"

# EXPECTED_ARCHS: the slices every Mach-O file of the result must contain
case "$ARCH" in
    universal) EXPECTED_ARCHS="x86_64 arm64" ;;
    arm64|x86_64) EXPECTED_ARCHS="$ARCH" ;;
    *) fail "invalid arch '$ARCH'" ;;
esac

# check_options: split OPTIONS into the OPTS array, accepting only
#   - the options listed in FLAGS (no value),
#   - the options listed in VALUED, followed by a number,
#   - the option=value pairs listed in LITERAL (the option, then exactly
#     that value),
#   - the options listed in FILEARGS, followed by a plain file name (no
#     directory), meant for a file of the archive or for 'auto'.
# FLAGS, VALUED, LITERAL and FILEARGS are space-separated, with a leading
# and a trailing space.
check_options() {
    local i=0 o
    OPTS=()
    read -r -a OPTS <<< "$OPTIONS"
    while [ $i -lt ${#OPTS[@]} ]; do
        o=${OPTS[$i]}
        if [[ "$FLAGS" == *" $o "* ]]; then
            :
        elif [[ "$VALUED" == *" $o "* ]]; then
            i=$((i + 1))
            [ $i -lt ${#OPTS[@]} ] && [[ "${OPTS[$i]}" =~ ^[0-9]+$ ]] \
                || fail "option $o needs a number"
        elif [[ "${LITERAL:-}" == *" $o="* ]]; then
            i=$((i + 1))
            [ $i -lt ${#OPTS[@]} ] && [[ "$LITERAL" == *" $o=${OPTS[$i]} "* ]] \
                || fail "option $o only accepts: $(printf '%s\n' $LITERAL | sed -n "s/^$o=//p" | tr '\n' ' ')"
        elif [[ "${FILEARGS:-}" == *" $o "* ]]; then
            i=$((i + 1))
            [ $i -lt ${#OPTS[@]} ] && [[ "${OPTS[$i]}" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] \
                || fail "option $o needs a file name without directory (a file of the archive)"
        else
            fail "option '$o' is not allowed"
        fi
        i=$((i + 1))
    done
}

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
            dsp|lib|json|wav|aif|aiff|flac|ogg|mp3) ;;
            *) fail "archive entry '$name': only .dsp, .lib, .json and soundfiles (.wav .aif .aiff .flac .ogg .mp3) are accepted" ;;
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

# copy_dsp_file: copy DSP_FILE into the current directory as $NAME.dsp,
# with the regular files next to it that an archive would accept (same
# names and extensions, at most MAX_TAR_SIZE bytes in all). Symbolic links
# and directories are left out.
copy_dsp_file() {
    local dir name size total=0 copied=""
    dir=$(dirname "$DSP_FILE")
    while IFS= read -r f; do
        name=$(basename "$f")
        [ "$f" = "$DSP_FILE" ] && continue
        [[ "$name" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] || continue
        case "${name##*.}" in
            dsp|lib|json|wav|aif|aiff|flac|ogg|mp3) ;;
            *) continue ;;
        esac
        size=$(wc -c < "$f" | tr -d ' ')
        total=$((total + size))
        [ $total -le $MAX_TAR_SIZE ] || fail "the files next to $DSP_FILE exceed $MAX_TAR_SIZE bytes"
        cp "$f" "./$name"
        copied="$copied $name"
    done < <(find "$dir" -maxdepth 1 -type f | sort)
    [ "$NAME.dsp" = "$(basename "$DSP_FILE")" ] || [ ! -e "$NAME.dsp" ] \
        || fail "$dir holds a $NAME.dsp that is not $DSP_FILE"
    cp "$DSP_FILE" "./$NAME.dsp"
    echo "dsp file: $(basename "$DSP_FILE") as $NAME.dsp, with:${copied:- nothing}" >> "$OUT/build.log"
}

# prepare_sources: create $OUT/$NAME, go there, and put the sources in it
prepare_sources() {
    mkdir -p "$OUT/$NAME"
    cd "$OUT/$NAME"
    if [ -n "$DSP_FILE" ]; then
        copy_dsp_file
    elif [ -n "$DSP" ]; then
        printf '%s\n' "$DSP" > "$NAME.dsp"
    else
        unpack_archive
    fi
}

# run_logged <command...>: log the Faust version and the command line, run
# the command with its output in build.log, print the log, fail on error.
# The command runs without the variables of these scripts: the faust2xxx
# scripts use variables of the same names without always setting them
# first (faust2caqt appends to OPTIONS, faust2max6 reads ARCH), and would
# take the workflow's values for their own.
run_logged() {
    {
        echo "faust: $(command -v faust)"
        faust --version | head -n 2
        echo "$*"
    } >> "$OUT/build.log"
    local status=0
    env -u DSP -u ARCHIVE -u DSP_FILE -u OPTIONS -u NAME -u ARCH -u OUT \
        "$@" >> "$OUT/build.log" 2>&1 || status=$?
    cat "$OUT/build.log"
    [ $status -eq 0 ] || fail "$1 failed with status $status"
}

# check_bundle_archs <bundle>: every Mach-O file of the bundle (binary,
# frameworks, plugins) must contain all of EXPECTED_ARCHS
check_bundle_archs() {
    local bundle=$1 f archs a n=0
    while IFS= read -r f; do
        file -b "$f" | grep -q 'Mach-O' || continue
        archs=$(lipo -archs "$f")
        for a in $EXPECTED_ARCHS; do
            [[ " $archs " == *" $a "* ]] || fail "${f#"$OUT/"} lacks the $a slice (has: $archs)"
        done
        n=$((n + 1))
    done < <(find "$bundle" -type f)
    [ $n -gt 0 ] || fail "$bundle holds no Mach-O file"
    echo "architectures: $EXPECTED_ARCHS in all $n Mach-O files of $bundle"
}

# thin_to_arch <file>: when ARCH is a single architecture, reduce a
# universal Mach-O file to it and sign it again (ad hoc). For the scripts
# that build both architectures without being asked (faust2puredata and
# faust2supercollider on an arm machine).
thin_to_arch() {
    local f=$1 archs
    [ "$ARCH" = universal ] && return 0
    archs=$(lipo -archs "$f")
    if [ "$archs" != "$ARCH" ] && [[ " $archs " == *" $ARCH "* ]]; then
        lipo "$f" -thin "$ARCH" -output "$f.thin"
        mv "$f.thin" "$f"
        codesign --sign - --force "$f"
    fi
}

# package <suffix>: zip $OUT/$NAME into $OUT/$NAME-<suffix>.zip
package() {
    cd "$OUT"
    rm -f "$NAME-$1.zip"
    # Without --noextattr, ditto stores the files' extended attributes as ._*
    # entries in the zip, which then reappear as stray files on extraction.
    ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$NAME-$1.zip"
    echo "wrote $OUT/$NAME-$1.zip"
}
