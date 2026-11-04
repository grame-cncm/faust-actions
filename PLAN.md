# faustosxservice — plan

Compile Faust programs into macOS binaries (Intel and Apple Silicon) with
GitHub Actions. The first target is Max/MSP externals built with
`faust2max6`. The user sends a `foo.dsp` file; the workflow compiles it and
returns the binary as a downloadable zip.

## 1. Why this works

- **One runner produces both architectures.** `faust2max6` accepts
  `-arch auto|arm64|x86_64|universal`. With `-universal` (alias of
  `-arch universal`), it compiles an arm64 slice and an x86_64 slice and
  merges them with `lipo`. A single arm64 GitHub runner (`macos-15`)
  therefore produces a `foo~.mxo` that runs on Intel and Apple Silicon Macs.
  An Intel runner is only needed to *run* the x86_64 slice natively, not to
  build it.
- **Max SDK.** `faust2max6` reads the `MAXSDK` variable and expects
  `$MAXSDK/max-includes` and `$MAXSDK/msp-includes` (default:
  `/usr/local/include/c74support/`, set in `faustpath`). Cloning
  [Cycling74/max-sdk-base](https://github.com/Cycling74/max-sdk-base)
  gives `c74support/` at its root, which is the directory `MAXSDK` must
  point to. ([Cycling74/max-sdk](https://github.com/Cycling74/max-sdk)
  itself now holds only the examples: it no longer includes
  `max-sdk-base` as a submodule.)
- **Signing.** `faust2max6` already ad-hoc signs the bundle
  (`codesign --sign - --force`) after its last copy, so the external
  loads on Apple Silicon without further work on the machine that
  built it.

## 2. Faust version

The `-arch` / `-universal` option of `faust2max6` was added to `master-dev`
on 2026-09-15 and is not in a numbered release yet. The workflow
therefore builds Faust from `master-dev`:

- `git clone --depth 1 --recursive -b master-dev https://github.com/grame-cncm/faust`
  (the `libraries` submodule is required);
- `make` then `sudo make install` (passwordless `sudo` on GitHub runners);
- cache the installed tree with `actions/cache`, keyed on the `master-dev`
  commit (`git ls-remote https://github.com/grame-cncm/faust master-dev`),
  so the 10–15 minute compiler build only runs when `master-dev` moves;
- print `faust --version` in the log: its `Source commit:` line identifies
  the compiler that produced each binary.

Once a release contains `-arch`, the build step can be replaced by
`brew install faust` or the official `.dmg`, with a workflow input to pick
the version.

## 3. Repository layout

```
faustosxservice/
├── .github/
│   ├── actions/setup-faust/   # composite action: build or restore Faust
│   └── workflows/max.yml      # faust2max6 job
├── scripts/
│   ├── build-max.sh           # runs faust2max6, packages the result
│   └── faustosx               # client: send a .dsp, wait, download
├── tests/
│   └── osc.dsp                # smoke-test program
└── README.md
```

## 4. The `max.yml` workflow

### Inputs (`workflow_dispatch`)

| input | meaning | default |
| :--- | :--- | :--- |
| `dsp` | Faust source code, as text | required |
| `name` | program name, without `.dsp` | `foo` |
| `options` | extra `faust2max6` options (`-mc`, `-nvoices 8`, `-soundfile`, `-double`…) | empty |
| `arch` | `universal`, `arm64` or `x86_64` | `universal` |

`workflow_dispatch` inputs are limited to about 65 KB in total: enough for
a single `.dsp`, not for local `import`s or soundfiles (see §6).

### Steps

1. Checkout this repository.
2. Restore or build Faust (§2).
3. `git clone --depth 1 https://github.com/Cycling74/max-sdk-base`
   (cacheable as well).
4. Validate `name` (`^[A-Za-z_][A-Za-z0-9_]*$`) and `options` against an
   allow-list of `faust2max6` options. Reject `-native` / `-opt native`:
   they would tune the code for the runner's CPU, not the user's.
5. Write the source to `$name.dsp` **from an environment variable**, never
   by expanding `${{ inputs.dsp }}` inside the script, which would let the
   Faust text inject shell commands:

   ```yaml
   - name: Compile
     env:
       DSP: ${{ inputs.dsp }}
       NAME: ${{ inputs.name }}
       OPTIONS: ${{ inputs.options }}
       ARCH: ${{ inputs.arch }}
       MAXSDK: ${{ runner.temp }}/max-sdk-base/c74support
     run: scripts/build-max.sh
   ```

6. `scripts/build-max.sh`:

   ```sh
   set -euo pipefail
   mkdir -p out && cd out
   printf '%s\n' "$DSP" > "$NAME.dsp"
   faust --version
   faust2max6 -arch "$ARCH" $OPTIONS "$NAME.dsp"
   lipo -info "$NAME~.mxo/Contents/MacOS/$NAME~"   # must list x86_64 arm64
   codesign --verify --verbose "$NAME~.mxo"
   ditto -c -k --norsrc --noextattr --keepParent . "../$NAME-max.zip"
   ```

   (`--noextattr`: otherwise the zip carries `._*` entries for the files'
   extended attributes.)

   `faust2max6` produces `foo~.mxo`, plus `foo.maxpat` and `ui.js`
   unless `-nopatch` is given. The three go into the zip. `ditto` keeps
   the bundle structure and the signature intact.

7. `actions/upload-artifact` with the zip, `archive: false` (the zip is
   uploaded as is, under its own name `$name-max.zip`, instead of being
   zipped a second time), `retention-days: 7`.
8. On failure, upload the Faust/C++ error log as well, so the user sees the
   compiler message.

## 5. Client script

`scripts/faustosx foo.dsp [options]` wraps the GitHub CLI:

```bash
gh workflow run max.yml -R <owner>/faustosxservice -f name=foo -f dsp="$(cat foo.dsp)"
```

It then finds the run it just started (`gh run list --workflow max.yml
--limit 1 --json databaseId`), waits with `gh run watch`, and fetches the
result with `gh run download <id> --name max-foo`. It also removes the
quarantine attribute from the downloaded `.mxo` (§7).

## 6. Later extensions

- **Several files.** For programs with local `import`s or soundfiles, add a
  `push` trigger on a `dsp/` directory (one subdirectory per program), or a
  `repository_dispatch` event whose payload carries a URL to a zip. The
  build script is unchanged.
- **Other targets.** Same structure, one job per architecture script:
  `faust2caqt`, `faust2au`, `faust2vst`, `faust2juce`… A matrix input
  `target` selects the script. Each target needs its own SDK (JUCE, Qt,
  VST3 SDK) installed or cached on the runner.
- **Intel test job.** Optionally load the external on an Intel runner
  (`macos-15-intel`) with a headless check (`dlopen` of the binary), to
  verify the x86_64 slice beyond `lipo -info`.
- **Public service.** Running a workflow requires write access to the
  repository. To let external users submit programs, put a small web
  front-end in front of it that holds the GitHub token, applies rate limits
  and returns the artifact link. The token must never reach the client.

## 7. Points to settle

- **Gatekeeper.** A downloaded zip is quarantined by macOS. With only an
  ad-hoc signature, users must run
  `xattr -dr com.apple.quarantine foo~.mxo` before Max loads it. Proper
  distribution needs a Developer ID certificate and notarization: store the
  certificate (`.p12`, base64) and the App Store Connect API key as
  repository secrets, import them into a temporary keychain, sign with
  `codesign --options runtime --timestamp`, then `xcrun notarytool submit
  --wait`. A `.mxo` bundle cannot be stapled on its own; notarize the zip
  or wrap it in a `.dmg` / `.pkg`.
- **`-osc`.** It links `-lOSCFaust`. `make install` does install
  `libOSCFaust.a`, but built for the runner's architecture only (arm64),
  so a universal link fails. Refused until the Faust build produces it
  universal (`make universal` in the Faust tree) or the workflow builds it
  separately for x86_64.
- **`-soundfile`.** Uses the static `libsndfile.a` shipped for `arm` and
  `intel` in `architecture/max-msp/sndfile`: should work on the runner,
  to verify. `-soundfile-dynamic` links the runner's Homebrew libsndfile,
  which users will not have: reject it.
- **Minimum macOS.** `faust2max6` builds with `-mmacosx-version-min=10.9`;
  check which Max versions and macOS versions the result actually loads on.
- **Cost.** macOS minutes are free on a public repository. On a private
  one they count about 10× Linux minutes. The Faust cache is what keeps a
  job at a few minutes.
- **Repository visibility.** Public (free minutes, but logs and artifacts
  of every run are visible to anyone) or private (paid minutes, private
  user code)?

## 8. Milestones

1. Repository, `max.yml` with Faust built from `master-dev`, manual
   `workflow_dispatch` on `tests/osc.dsp`; check `lipo -info` lists both
   architectures and the external loads in Max on an Apple Silicon Mac.
2. Same external tested on an Intel Mac.
3. Faust and Max SDK caches; measure build time with a warm cache.
4. Option validation, error log artifact, `scripts/faustosx` client.
5. Signing and notarization, if the binaries are to be distributed.
6. Further targets (`faust2caqt`, `faust2au`…), then multi-file input.
