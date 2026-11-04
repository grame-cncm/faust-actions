# faustosxservice

Compile Faust programs into macOS binaries with GitHub Actions. One run
takes the source of one `.dsp` file and returns a universal (Intel and
Apple Silicon) binary as a zip artifact.

Supported target: Max/MSP externals, built with `faust2max6`. See
[PLAN.md](PLAN.md) for the design and the next steps.

## Compile a Max external

```sh
gh workflow run max.yml -f name=osc -f dsp="$(cat tests/osc.dsp)"
gh run watch
gh run download --name osc-max.zip
```

A program that imports local files (`.lib`, other `.dsp`, soundfiles)
goes in the `archive` input instead of `dsp`, packed flat:

```sh
cd tests/withlib
gh workflow run max.yml -f name=withlib \
  -f archive="$(tar -cf - withlib.dsp mylib.lib | gzip -9 | base64)"
```

Use a separate `gzip` rather than `tar -z`: on macOS, `tar -czf -`
pads its output to 10 KB, which counts against the 65,535-character
limit of all inputs together.

Inputs of the `max.yml` workflow:

| input | meaning | default |
| :--- | :--- | :--- |
| `dsp` | Faust source code, as text | empty |
| `archive` | instead of `dsp`: base64 of a `tar.gz` holding `<name>.dsp` and the files it imports, without directories | empty |
| `name` | program name, without `.dsp` | `foo` |
| `options` | extra `faust2max6` options, from the allow-list in `scripts/build-max.sh` | empty |
| `arch` | `universal`, `arm64` or `x86_64` | `universal` |
| `tag` | free text added to the run name, to find the run again | empty |

Exactly one of `dsp` and `archive` is given; all inputs together are
limited to 65,535 characters. Archive entries must be regular files with
plain names and the extensions `.dsp`, `.lib`, `.wav`, `.aif`, `.aiff`,
`.flac`, `.ogg` or `.mp3`, at most 600 KB once decompressed.

The `<name>-max.zip` artifact holds a `<name>/` folder with `<name>~.mxo`,
`<name>.maxpat`, `ui.js` and the sources. The `<name>-log` artifact holds
the compiler output, also when the compilation fails.

The external is ad-hoc signed only. After downloading, remove the
quarantine attribute before Max can load it:

```sh
xattr -dr com.apple.quarantine "osc~.mxo"
```

## Compile a CoreAudio + Qt application

```sh
gh workflow run caqt.yml -f name=osc -f dsp="$(cat tests/osc.dsp)"
gh run watch
```

Do not fetch the application with `gh run download`: it unpacks the zip
without the symbolic links of the Qt frameworks, which breaks their
signature. Download the zip as it is, then unpack it with `ditto`
(Finder's Archive Utility also keeps the links):

```sh
run=<run id>
id=$(gh api repos/grame-cncm/faustosxservice/actions/runs/$run/artifacts \
       --jq '.artifacts[] | select(.name == "osc-caqt.zip") | .id')
gh api repos/grame-cncm/faustosxservice/actions/artifacts/$id/zip > osc-caqt.zip
ditto -x -k osc-caqt.zip .
```

Same inputs as `max.yml`, plus `qt` (Qt version, default `6.8.3`, which
runs on macOS 12 and later). `options` takes `faust2caqt` options from
the allow-list in `scripts/build-caqt.sh` (`-midi`, `-nvoices <n>`,
`-effect auto`, `-preset auto`, `-me`...). The `<name>-caqt.zip`
artifact holds `<name>/<name>.app`, Qt included, and the sources. Remove
the quarantine attribute the same way:

```sh
xattr -dr com.apple.quarantine osc.app
```

## Compile JUCE plugins (AU, VST3, Standalone)

```sh
gh workflow run juce.yml -f name=osc -f dsp="$(cat tests/osc.dsp)"
gh run watch
```

Same inputs as `max.yml`, plus `juce` (JUCE version, default `8.0.10`).
`options` takes `faust2juce` options from the allow-list in
`scripts/build-juce.sh` (`-midi`, `-nvoices <n>`, `-osc`, `-jsynth`,
`-effect <file.dsp|auto>`, `-presets <file.json>`...); the files named
by `-effect` and `-presets` go in the `archive`. The `<name>-juce.zip`
artifact holds `<name>/<name>.component` (AU), `<name>.vst3` and
`<name>.app` (Standalone), universal by default. Download it as the raw
zip, as for `caqt` (above), and copy the plugins to
`~/Library/Audio/Plug-Ins/Components` and `~/Library/Audio/Plug-Ins/VST3`.

## Compile for Pure Data, SuperCollider and Csound

```sh
gh workflow run puredata.yml -f name=osc -f dsp="$(cat tests/osc.dsp)"
gh workflow run supercollider.yml -f name=osc -f options=-noprefix -f dsp="$(cat tests/osc.dsp)"
gh workflow run csound.yml -f name=osc -f dsp="$(cat tests/osc.dsp)"
```

Same inputs as `max.yml`, plus the version of the headers used: `pd`
(a tag of pure-data/pure-data, default `0.56-5`), `sc` (a tag of
supercollider/supercollider, default `Version-3.14.1`) or `csound` (a
Csound release, default `6.18.1`, whose universal macOS installer
provides the headers). The artifacts hold `<name>~.pd_darwin`;
`<name>.scx` (plus `<name>_supernova.scx` with `-sn`) and the
`<name>.sc` class file; or `<name>.dylib`. The `.pd` patch that
`faust2pd` writes is not produced: `faust2pd` is not installed on the
runner.

## How it works

- `.github/actions/setup-faust` builds the Faust compiler from
  `grame-cncm/faust` `master-dev` and caches it, keyed on the commit: only
  the first run after `master-dev` moves rebuilds it. The `-arch` option of
  `faust2max6` is not in a numbered Faust release yet.
- `.github/workflows/max.yml` clones the
  Max SDK headers ([max-sdk-base](https://github.com/Cycling74/max-sdk-base)) and runs
  `scripts/build-max.sh` on a `macos-15` (arm64) runner; `faust2max6
  -arch universal` cross-compiles the x86_64 slice.

## Test locally

```sh
DSP="$(cat tests/osc.dsp)" NAME=osc ARCH=universal OPTIONS="" \
MAXSDK=/path/to/max-sdk-base/c74support OUT=/tmp/out \
scripts/build-max.sh
```

`faust` and `faust2max6` must be on the `PATH`, from a Faust that has
`faust2max6 -arch`.
