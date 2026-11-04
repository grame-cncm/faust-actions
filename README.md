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

Inputs of the `max.yml` workflow:

| input | meaning | default |
| :--- | :--- | :--- |
| `dsp` | Faust source code, as text (about 65 KB at most) | required |
| `name` | program name, without `.dsp` | `foo` |
| `options` | extra `faust2max6` options, from the allow-list in `scripts/build-max.sh` | empty |
| `arch` | `universal`, `arm64` or `x86_64` | `universal` |
| `tag` | free text added to the run name, to find the run again | empty |

The `<name>-max.zip` artifact holds a `<name>/` folder with `<name>~.mxo`,
`<name>.maxpat`, `ui.js` and the source. The `<name>-log` artifact holds
the compiler output, also when the compilation fails.

The external is ad-hoc signed only. After downloading, remove the
quarantine attribute before Max can load it:

```sh
xattr -dr com.apple.quarantine "osc~.mxo"
```

## How it works

- `.github/actions/setup-faust` builds the Faust compiler from
  `grame-cncm/faust` `master-dev` and caches it, keyed on the commit: only
  the first run after `master-dev` moves rebuilds it. The `-arch` option of
  `faust2max6` is not in a numbered Faust release yet.
- `.github/workflows/max.yml` clones the
  [Max SDK](https://github.com/Cycling74/max-sdk) and runs
  `scripts/build-max.sh` on a `macos-15` (arm64) runner; `faust2max6
  -arch universal` cross-compiles the x86_64 slice.

## Test locally

```sh
DSP="$(cat tests/osc.dsp)" NAME=osc ARCH=universal OPTIONS="" \
MAXSDK=/path/to/max-sdk/source/max-sdk-base/c74support OUT=/tmp/out \
scripts/build-max.sh
```

`faust` and `faust2max6` must be on the `PATH`, from a Faust that has
`faust2max6 -arch`.
