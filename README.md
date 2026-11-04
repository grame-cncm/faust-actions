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
gh run download --name osc-caqt.zip
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
