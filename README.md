# faust-actions

Compile Faust programs into macOS binaries, universal (Intel and Apple
Silicon) by default, with GitHub Actions:

| target | script | result |
| :--- | :--- | :--- |
| `max` | `faust2max6` | Max external `<name>~.mxo`, help patch, `ui.js` |
| `caqt` | `faust2caqt` | CoreAudio + Qt application `<name>.app`, Qt included |
| `jaqt` | `faust2jaqt` | JACK + Qt application `<name>.app`, **Apple Silicon only**, needs JACK on the user's machine |
| `juce` | `faust2juce` | JUCE plugins: `<name>.component` (AU), `<name>.vst3`, `<name>.app` (Standalone) |
| `puredata` | `faust2puredata` | Pure Data external `<name>~.pd_darwin` |
| `supercollider` | `faust2supercollider` | UGen `<name>.scx` and class file `<name>.sc` |
| `csound` | `faust2csound` | Csound opcode `<name>.dylib` |

It is an **action**, for the workflows of any repository: on a `.dsp`
file of the repository, or on a source received as text by a workflow
started by a service (faustservice's compilations run that way, in a
separate private repository). See [PLAN.md](PLAN.md) for the
design, the measurements and the next steps. MIT license, see
[LICENSE](LICENSE). This repository was first named `faustosxservice`;
GitHub redirects the old address.

## Use the action in your repository

```yaml
jobs:
  macos:
    runs-on: macos-15            # an arm64 macOS runner is required
    steps:
      - uses: actions/checkout@v7
      - uses: grame-cncm/faust-actions@v1
        id: faust
        with:
          target: juce
          dsp: dsp/reverb.dsp    # the .lib, .dsp, .json and soundfiles next to it come along
          options: -midi
      - uses: actions/upload-artifact@v7
        with:
          path: ${{ steps.faust.outputs.zip }}
          archive: false         # keeps the zip as it is (see "Download" below)
```

`@v1` follows the compatible 1.x.y releases; pin `@v1.0.0`, or a commit
(`@<sha>`), to keep exactly the same version.

| input | meaning | default |
| :--- | :--- | :--- |
| `target` | `max`, `caqt`, `jaqt`, `juce`, `puredata`, `supercollider` or `csound` | required |
| `dsp` | path of the `.dsp` file in the workspace; the files next to it with the extensions `.lib`, `.dsp`, `.json`, `.wav`, `.aif`, `.aiff`, `.flac`, `.ogg`, `.mp3` come along (regular files only, 600 KB in all) | required |
| `name` | program name, letters, digits and `_` | the name of the `.dsp` file |
| `options` | options of the `faust2xxx` script, from the allow-list of `scripts/build-<target>.sh` | empty |
| `arch` | `universal`, `arm64` or `x86_64` (`jaqt`: `arm64` only) | `universal` |
| `faust-ref` | branch of grame-cncm/faust to build Faust from | `master-dev` |
| `qt` | Qt version (`caqt`, `jaqt`) | `6.8.3` |
| `juce` | JUCE tag (`juce`) | `8.0.10` |
| `pd` | Pure Data tag whose `m_pd.h` is used (`puredata`) | `0.56-5` |
| `sc` | SuperCollider tag whose headers are used (`supercollider`) | `Version-3.14.1` |
| `csound` | Csound release whose headers are used (`csound`) | `6.18.1` |

| output | meaning |
| :--- | :--- |
| `zip` | path of the zip holding `<name>/`, with the binaries and the sources |
| `log` | path of `build.log`, which also holds the error when the build fails |
| `name` | program name |
| `faust-commit` | Faust commit used |

Faust is built from source (about 3 min 30) the first time, then
restored from the cache of your repository while `faust-ref` does not
move; Qt, JUCE and the Csound headers are cached the same way. The runs
use your repository's Actions minutes, free on a public repository. The
results are ad-hoc signed only: users remove the quarantine attribute
(below) or you sign and notarize them in a later step.

The `setup-faust`, `setup-qt` and `setup-juce` actions can also be used
alone, for instance to run another `faust2xxx` script:

```yaml
- uses: grame-cncm/faust-actions/setup-faust@v1
- uses: grame-cncm/faust-actions/setup-qt@v1
  id: qt
```

## Run it as a service

A workflow started by `workflow_dispatch` can receive the source as text
and pass it to the action with `dsp-from-event: "true"`: the action then
reads the `dsp` or `archive` input from the event payload, never from
the environment, so that the log does not show the source. The caller
needs write access to the repository holding the workflow.

```yaml
on:
  workflow_dispatch:
    inputs:
      dsp: { type: string, default: "" }
      archive: { type: string, default: "" }   # instead of dsp, see below
      name: { type: string, default: foo }
      options: { type: string, default: "" }
jobs:
  max:
    runs-on: macos-15
    steps:
      - uses: grame-cncm/faust-actions@v1
        id: faust
        with:
          target: max
          dsp-from-event: "true"
          name: ${{ inputs.name }}
          options: ${{ inputs.options }}
      - uses: actions/upload-artifact@v7
        with:
          path: ${{ steps.faust.outputs.zip }}
          archive: false
```

```sh
gh workflow run max.yml -R <owner>/<repo> -f name=osc -f dsp="$(cat tests/osc.dsp)"
```

A program that imports local files (`.lib`, other `.dsp`, `.json`,
soundfiles) goes in the `archive` input instead of `dsp`, packed flat,
at most 600 KB once decompressed:

```sh
cd tests/withlib
gh workflow run max.yml -R <owner>/<repo> -f name=withlib \
  -f archive="$(tar -cf - withlib.dsp mylib.lib | gzip -9 | base64)"
```

Use a separate `gzip` rather than `tar -z`: on macOS, `tar -czf -` pads
its output to 10 KB, which counts against the 65,535-character limit of
all inputs together. On a public repository, a run, its name and its
artifacts are visible until they are deleted: see [PLAN.md](PLAN.md),
§7, "Privacy", for the deletion after download and the planned
encryption.

## Download

Fetch the zip as it is and unpack it with `ditto` (or Finder's Archive
Utility). `gh run download` unpacks it without the symbolic links of the
frameworks, which breaks the signature of the Qt applications:

```sh
run=<run id>
repo=<owner>/<repo>
id=$(gh api repos/$repo/actions/runs/$run/artifacts \
       --jq '.artifacts[] | select(.name == "osc-caqt.zip") | .id')
gh api repos/$repo/actions/artifacts/$id/zip > osc-caqt.zip
ditto -x -k osc-caqt.zip .
```

Then remove the quarantine attribute, for instance:

```sh
xattr -dr com.apple.quarantine osc
```

Plugins go in `~/Library/Audio/Plug-Ins/Components` (AU) and
`~/Library/Audio/Plug-Ins/VST3`. The `jaqt` applications include Qt but
not `libjack`: they load the user's, from `/usr/local/lib` (JackOSX
installer) or `/opt/homebrew/lib` (Homebrew). The Pure Data target
produces no `.pd` patch: `faust2pd` is not installed on the runner.

## Test locally

The build scripts run outside GitHub with the same environment the
action gives them:

```sh
DSP_FILE=tests/osc.dsp ARCH=universal OUT=/tmp/out \
MAXSDK=/path/to/max-sdk-base/c74support scripts/build-max.sh
```

`faust` and the `faust2xxx` scripts must be on the `PATH`, from a Faust
whose `faust2max6` and `faust2caqt` have `-arch` (`master-dev` since
2026-11-04). `DSP` (text) or `ARCHIVE` (base64) can replace `DSP_FILE`.
