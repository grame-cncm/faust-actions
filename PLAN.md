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

- resolve the `master-dev` commit
  (`git ls-remote https://github.com/grame-cncm/faust refs/heads/master-dev`)
  and fetch exactly that commit, with its submodules (the `libraries`
  submodule is required);
- `make` then `make install PREFIX=$RUNNER_TEMP/faust-install`, so the
  whole installation is one directory, without `sudo`;
- cache that directory, keyed on the commit, with separate
  `actions/cache/restore` and `actions/cache/save` steps. The save runs right
  after the build: a plain `actions/cache` saves only when the whole job
  succeeds, and a job fails whenever the user's program does not compile.
  The build (about 3 min 30 on `macos-15`) therefore runs once per
  `master-dev` commit; a cache hit restores Faust in about 3 s;
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
│   ├── actions/setup-qt/      # composite action: install or restore Qt
│   ├── actions/setup-juce/    # composite action: fetch or restore JUCE
│   ├── workflows/max.yml      # faust2max6 job
│   ├── workflows/caqt.yml     # faust2caqt job (§9)
│   └── workflows/juce.yml     # faust2juce plugins job (§10)
├── scripts/
│   ├── lib.sh                 # shared: inputs, archive, logs, checks, zip
│   ├── build-max.sh           # runs faust2max6, packages the result
│   ├── build-caqt.sh          # runs faust2caqt, packages the result
│   ├── build-juce.sh          # runs faust2juce and CMake, packages the plugins
│   └── faustosx               # client: send a .dsp, wait, download (to do)
├── tests/
│   ├── osc.dsp                # smoke-test program
│   └── withlib/               # program importing a local .lib (archive)
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
| `archive` | instead of `dsp`: base64 of a `tar.gz` holding `<name>.dsp` and the files it imports | empty |
| `tag` | free text added to the run name, so a client can find its run | empty |

Exactly one of `dsp` and `archive` is given. `workflow_dispatch` inputs
are limited to 65,535 characters in total: enough for a single `.dsp`, or
for an archive of about 48 KB once compressed, which holds a program and
its `.lib` files but rarely soundfiles (see "Several files" below).

### Several files: the `archive` input

A program may import local `.lib` files, other `.dsp` files
(`component("x.dsp")`), or read soundfiles (`-soundfile`). faustservice
accepts such programs as a zip, of at most 500 KB once extracted. The
`archive` input carries these files:

- the client packs them flat, without directories:
  `tar -cf - prog.dsp mylib.lib | gzip -9 | base64` (`base64 -w0` with
  GNU coreutils). Compress with a separate `gzip` rather than `tar -z`:
  writing to a pipe, bsdtar (macOS) pads its output with zeros to
  10,240 bytes, so a 618-byte archive takes 13,656 characters of input
  instead of about 830. `COPYFILE_DISABLE=1` keeps the macOS `tar` from
  storing extended attributes, which is cleaner but not required;
- `build-max.sh` decodes the input, decompresses at most 600 KB (more is
  refused, which also stops a compression bomb), lists the entries before
  extracting anything, and refuses the whole archive if one entry is not
  a regular file, has a name with `/`, starting with `.` or outside
  `[A-Za-z0-9._-]`, or an extension other than `.dsp`, `.lib`, `.wav`,
  `.aif`, `.aiff`, `.flac`, `.ogg`, `.mp3`. It then extracts with
  `--no-mac-metadata --no-xattrs --no-acls --no-fflags`: the macOS `tar`
  hides AppleDouble `._*` entries from its listing and, by default, turns
  them into extended attributes of the matching file (`--no-xattrs` alone
  does not prevent it);
- `<name>.dsp` must be one of the entries: it is the program given to
  `faust2max6`; the other files sit next to it, where Faust looks for
  imports and soundfiles;
- the zip returned holds the same `<name>/` folder as with `dsp`, so the
  imported files come back with the external.

`faust -e`, which expands a program and all its imports into a single
`.dsp`, was ruled out: it also expands the library code and the tables.
Over the 265 programs of the Faust `examples/` directory, half are larger
than 38 KB once expanded, 120 are larger than 60 KB, and the largest
(`physicalModeling/faust-stk/piano1.dsp`) reaches 42 MB, whereas the
sources they come from are a few KB.

When a program does not fit, the next step is to pass a URL instead of
the files: faustservice would serve the session as `<key>/source.zip`
(a new endpoint; today only `<key>/user_code.dsp`, the main file, is
served), and the workflow would download it, accepting only URLs of the
faustservice host. No size limit then, beyond faustservice's own 500 KB.

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

It passes a unique `tag` input and finds its run by the run name
(`max <name> <tag>`) in `gh run list --workflow max.yml --json
databaseId,displayTitle`, waits with `gh run watch`, and fetches the result
with `gh run download <id> --name foo-max.zip`, which unpacks the zip into
`foo/` and keeps the executable bit and the signature. It also removes the
quarantine attribute from the downloaded `.mxo` (§8).

## 6. Later extensions

- **Larger programs.** Beyond the `archive` input (§4), a URL input
  pointing to the session on faustservice (§4, "Several files"), or a
  `push` trigger on a `dsp/` directory (one subdirectory per program).
- **Other targets.** Same structure, one job per architecture script:
  `faust2caqt`, `faust2au`, `faust2vst`, `faust2juce`… A matrix input
  `target` selects the script. Each target needs its own SDK (JUCE, Qt,
  VST3 SDK) installed or cached on the runner.
- **Intel test job.** Optionally load the external on an Intel runner
  (`macos-15-intel`) with a headless check (`dlopen` of the binary), to
  verify the x86_64 slice beyond `lipo -info`.
- **Public service.** Running a workflow requires write access to the
  repository. External users can fork the repository and run the workflow
  in their fork, or go through a server that holds the GitHub token: the
  existing faustservice, see §7. The token must never reach the client.

## 7. Use from faustservice

[faustservice](https://github.com/grame-cncm/faustservice) (the remote
compilation server behind the Faust IDE export, deployed as a docker image
built from its `server` branch) can delegate its macOS Max targets to this
workflow without any change to its C++ code.

### How faustservice compiles for macOS today

- A request `<key>/osx/max/binary.zip` makes the server run
  `make -C <session>/osx/max binary.zip` (`make()` in `server.cpp`), one
  thread per connection, waiting for `make` to finish. If no `binary.zip`
  file exists afterwards, the user gets a generic "cannot compile" page;
  if it exists, it is sent. `make` sees an existing `binary.zip` as up to
  date, so a session compiles a target once.
- Faust errors are caught earlier: at upload, the server runs `faust` on
  Linux and stores the messages in `<key>/errors.log`. A macOS target thus
  only fails on C++, SDK or packaging problems.
- The makefiles do not compile for macOS themselves; they call a helper
  script. `makefiles/dockerosx/Makefile.max` is:

  ```make
  binary.zip : $(faustfile)
  	dockerOSX faust2max6 $(faustfile) $(OPT)
  	zip -r binary.zip *
  ```

  `$(OPT)` holds the options of the program's `declare options`, filtered
  by `faustOptions.cpp`. The helper has been swapped once already:
  `bin/remoteOSX` copied the files over SSH to a Mac and ran the script
  there; `bin/dockerOSX` now runs it in the `faust:cross-osx` image
  (osxcross on Linux). The Dockerfile installs `dockerOSX` and replaces
  `makefiles/osx` with `makefiles/dockerosx`.

### Integration: a `githubOSX` helper

A third helper, `bin/githubOSX`, with the same command line as
`remoteOSX`: the script name first, then options and `.dsp` / `.lib`
files.

1. Collect the arguments: the script (only `faust2max6` at first; any
   other script fails at once), the options, the `.dsp` file and any
   `.lib` files of the session.
2. Build the inputs: `name` from the `.dsp` file name, `options`, and the
   source. A single `.dsp` without `.lib` goes in the `dsp` input; several
   files go in an `archive` input (see "Changes in this repository"
   below).
3. Create a unique `tag` (session key plus a random suffix) and start the
   run through the REST API:
   `POST /repos/grame-cncm/faustosxservice/actions/workflows/max.yml/dispatches`
   with `{"ref": "main", "inputs": {...}}`. `curl` and `jq` are enough; `gh`
   is not needed in the image.
4. Find the run: `GET .../actions/workflows/max.yml/runs?event=workflow_dispatch`,
   keep the run whose `display_title` contains the tag; retry for a few
   seconds, the run appears with a delay.
5. Poll `GET .../actions/runs/<id>` every 5 s until `status` is
   `completed`, with an overall limit (300 s to start with); past the
   limit, cancel the run (`POST .../actions/runs/<id>/cancel`) and fail.
6. On success, list the run's artifacts, download `<name>-max.zip` with
   `GET .../actions/artifacts/<id>/zip` (uploaded with `archive: false`,
   so the response is the zip itself), write it to a temporary file, then
   rename it to `binary.zip`: the server must never see a partial
   `binary.zip`, which it would send as a valid result.
7. On failure, download `<name>-log` (a zip holding `build.log`), copy the
   log to stderr, which goes to the server's log, and exit with a non-zero
   status, so no `binary.zip` exists and the user gets the error page.

The makefiles go in a new `makefiles/githubosx/` directory, one per Max
target, without the final `zip -r`, since `githubOSX` writes `binary.zip`
itself:

```make
faustfile ?= $(wildcard *.dsp)

binary.zip : $(faustfile)
	githubOSX faust2max6 $(faustfile) $(wildcard *.lib) $(OPT)
```

with `-mc`, `-nvoices 16`, `-midi` added for `max-mc`, `max-poly` and
`max-poly-mc` as in `makefiles/dockerosx`. The zip holds a `<name>/`
folder with `<name>~.mxo`, `<name>.maxpat`, `ui.js` and the source.

In the faustservice Dockerfile:

- install `bin/githubOSX` next to `dockerOSX`, plus `curl` and `jq` if
  the base image lacks them;
- after moving `makefiles/dockerosx` to `makefiles/osx`, copy the
  `Makefile.max*` files of `makefiles/githubosx` over it. The other macOS
  targets (Pure Data, SuperCollider, VST, Qt, Csound, plot) stay on
  `dockerOSX` until this repository builds them.

### GitHub token

- A fine-grained personal access token, owner `grame-cncm`, repository
  `faustosxservice` only, permission *Actions: read and write* (start,
  read and cancel runs, download artifacts). It can do nothing else.
- Given to the container at run time, never written into the image or a
  repository: `docker run --env-file /etc/faustservice/github.env ...`,
  with `FAUSTOSX_TOKEN=...` in that file (mode 600). `faustweb` runs
  `make` with `system()`, so the variable reaches `githubOSX`.
- Fine-grained tokens expire. Note the expiry date and renew it, or use a
  GitHub App installation token, which does not expire but needs an app
  registered on the organization.

### Changes in this repository

- The `archive` input (§4, "Several files"): implemented. `githubOSX`
  packs the session's files flat (`tar -cf - * | gzip -9 | base64 -w0`, run in the
  session's source directory, leaving out `binary.zip` and other outputs),
  checks that all inputs together stay under 65,535 characters, and fails
  with a clear message beyond. Sessions that do not fit wait for the URL
  input.
- The options allow-list of `build-max.sh` must accept every option that
  `faustOptions.cpp` lets through, or programs that compile today with
  `dockerOSX` would be refused. Compare the two lists and align them.

### Delays and limits

- A run takes about 25 s with a warm cache, plus the wait for a macOS
  runner (often 10–30 s, more when GitHub is loaded), plus about 3 min 30
  once after each `master-dev` commit. The HTTP front-end in front of
  `faustweb` and the Faust IDE must wait at least 5 minutes, or the IDE
  must use `<key>/osx/max/precompile` and then fetch `binary.zip`.
- The number of macOS jobs running at the same time is limited by the
  organization's GitHub plan (5 on the free plan); further requests queue.
- During a GitHub incident (as on 2026-11-04, "Git Operations" and
  "Actions" degraded), runs fail or wait. `githubOSX` can fall back to
  `dockerOSX` when the dispatch itself fails.
- **Privacy.** See "Privacy" below.

### Privacy

faustservice does not publish its users' code today. On a public
repository, a run is visible to anyone while it exists: its page and its
log (the web page is public; the log is downloadable by any GitHub
account, `GET .../runs/<id>/logs` answers 403 without a token), and its
artifacts, which hold the sources next to the binary.

- **Not in the log any more.** The log prints, in the header of each
  step, the environment given to it: with `DSP: ${{ inputs.dsp }}` the
  whole source was in the log (checked on a `puredata` run). The
  workflows no longer pass `dsp` and `archive` in the environment;
  `lib.sh` reads them from the event payload (`$GITHUB_EVENT_PATH`, with
  `jq`, or Python when `jq` is missing), which the log does not show.
  `name`, `options` and `tag` remain visible, in the step header and in
  the run name.
- **Deleted after download.** Once `githubOSX` has the zip, it deletes the
  whole run with the same token (permission *Actions: read and write*):
  `DELETE /repos/grame-cncm/faustosxservice/actions/runs/<run_id>`, which
  removes the run, its log and its artifacts. Finer:
  `DELETE .../actions/artifacts/<id>` and `DELETE .../actions/runs/<id>/logs`.
  If the deletion fails, the 7-day retention of the artifacts and the log
  retention of the repository (Settings > Actions, to lower to 1 day)
  are the fallback. The caches hold Faust, Qt, JUCE and headers only,
  never user code. What GitHub keeps internally after a deletion is not
  documented.
- **The window.** Between the dispatch and the deletion (about 30 s to
  5 minutes, more when runners are scarce), someone watching the Actions
  tab can see the run name (program name and tag) and download the
  artifact. Use a neutral `name` (for instance the session key) and set
  the program name back when unpacking, to hide even the name.
- **Encryption, to remove the window** (not implemented):
  - a repository secret `FAUSTOSX_KEY` (random, 32 bytes, base64), also
    given to faustservice next to the GitHub token;
  - `githubOSX` encrypts the archive before sending it:
    `openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:FAUSTOSX_KEY | base64`,
    in a new `encrypted` input; `lib.sh` decrypts it before
    `unpack_archive`, with the secret passed as an environment variable
    (GitHub masks secrets in logs);
  - the build script encrypts the zip the same way before the upload,
    and `githubOSX` decrypts it after the download;
  - errors in `build.log` hold the user's source lines (Faust messages
    quote them): encrypt the log artifact too;
  - cost: base64 grows the payload by a third against the 65,535-character
    input limit, so about 36 KB of compressed sources at most.
  Only a run with a neutral name and opaque data then remains visible,
  for a few minutes. This does not settle the question of GitHub's terms
  (§8, "Terms of use").
- Otherwise, a private repository makes the runs paid (about $0.06 per
  compilation, see §8, "Cost").

### Steps

1. In this repository: `archive` input, options aligned with
   `faustOptions.cpp`.
2. `bin/githubOSX`, tested by hand against GitHub with a token, on a
   single `.dsp`, on a `.dsp` with a `.lib`, on a program that fails to
   compile in C++, and with an overall limit too short to finish.
3. `makefiles/githubosx/` and the Dockerfile changes, on a branch of
   faustservice made from `server`.
4. Deploy on a test instance; export from the Faust IDE to the four Max
   targets; check the delays and that the externals load in Max.
5. Then the other macOS targets, as this repository learns to build them.

## 8. Points to settle

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
- **Cost on a public repository.** Standard GitHub-hosted runners, which
  include `macos-15`, are free on a public repository, and do not draw on
  the included usage: compilations cost nothing, whatever their number.
  What remains are limits (checked 2026-11-04 on the
  [Actions limits](https://docs.github.com/en/actions/reference/limits)
  page):

  - at most 5 macOS jobs at the same time on the Free, Pro and Team plans
    (50 on Enterprise), out of 20 jobs in all on Free; further runs wait
    in the queue. GitHub Support can raise these limits;
  - at most 6 hours per job, far above the minute a compilation takes;
  - artifact storage of 500 MB and cache storage of 10 GB on the Free
    plans, as on a private repository;
  - 500 workflow runs queued per 10 seconds per repository, and 5,000 REST
    API requests per hour for the token `githubOSX` uses (each compilation
    needs about 20: dispatch, a poll every 5 s, artifact list, download).

  **Terms of use.** The
  [GitHub Terms for Additional Products](https://docs.github.com/en/site-policy/github-terms/github-terms-for-additional-products-and-features)
  say that Actions should not be used, with GitHub-hosted runners, for
  "any other activity unrelated to the production, testing, deployment,
  or publication of the software project associated with the
  repository", nor to provide a service offering Actions for commercial
  purposes, nor as "part of a serverless application". faustservice is
  not commercial, but compiling its users' programs on demand is not the
  development of faustosxservice itself: this is a grey area, the same on
  a public or a private repository, and misuse may lead to disabled
  repositories. Before opening it to faustservice users, ask GitHub
  Support whether this use is acceptable, and keep `dockerOSX` as a
  fallback. A self-hosted macOS runner (a Mac at GRAME registered on the
  repository) is not covered by that clause and costs no runner minutes.

- **Cost on a private repository** (GitHub pricing since 2026-01-01,
  checked 2026-11-04):

  - the included usage is a dollar amount per month, not a number of
    minutes: $12 on GitHub Free for organizations (the plan of
    `grame-cncm`, read with `gh api orgs/grame-cncm --jq .plan.name`),
    $18 on Team, $300 on Enterprise Cloud. Each minute is deducted at its
    own rate; there is no minute multiplier any more;
  - a standard macOS runner (`macos-15`) costs $0.062 per minute, about
    ten times a Linux 2-core runner ($0.006);
  - each job is rounded up to the whole minute.

  For this workflow, a compilation takes 25 to 42 s, billed 1 minute, so
  about $0.06; the run that rebuilds Faust after a new `master-dev`
  commit takes about 4 minutes, about $0.25 more. The $12 of the Free
  plan therefore cover about 190 compilations a month while `master-dev`
  does not move.

  | compilations per month | gross cost | beyond the $12 included |
  | :--- | :--- | :--- |
  | 100 | $6.20 | $0 |
  | 500 | $31 | about $19 |
  | 1,000 | $62 | about $50 |
  | plus a Faust rebuild every day (30) | about $7.50 | added to the above |

  Consequences for a private repository:

  - without a payment method on file, runs are blocked once the included
    usage is spent, until the next month: faustservice would get
    failures. With a payment method, usage beyond it is billed unless a
    budget limits it, and GitHub does not document a $0 default budget:
    set one explicitly, and enable the e-mail alerts at 90% and 100% of
    the included usage;
  - Faust rebuilds become a noticeable share when `master-dev` moves
    often. To bound them, follow `master-dev` at most once a day or once
    a week (resolve the commit from a scheduled workflow, or round the
    cache key to the day), or pin a chosen Faust commit or release;
  - artifact storage included on GitHub Free is 500 MB, shared with
    GitHub Packages. With zips of about 0.9 MB kept 7 days, that is about
    500 compilations a week; lower `retention-days` (1 is enough for
    faustservice, which downloads the zip at once) if needed. The cache
    has 10 GB per repository; Faust takes 46.5 MB per `master-dev`
    commit, and GitHub evicts the oldest entries.

  Sources: [Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing),
  [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions),
  [Pricing changes for GitHub Actions](https://github.com/resources/insights/2026-pricing-changes-for-github-actions).
- **Repository visibility.** The repository is public: free minutes, but
  the logs and artifacts of every run are visible to anyone. To revisit
  if user code must stay private (§7, privacy).

## 9. The `caqt.yml` workflow

`caqt.yml` compiles a program with `faust2caqt` into a CoreAudio + Qt
application, universal by default. It has the inputs of `max.yml`
(`dsp` or `archive`, `name`, `options`, `arch`, `tag`) plus `qt`, the Qt
version, and returns `<name>-caqt.zip`, holding a `<name>/` folder with
`<name>.app` and the sources, plus `<name>-log`.

- **Architectures.** `faust2caqt` takes `-arch auto|arm64|x86_64|universal`
  (and `-universal`), as `faust2max6` does: the other values than `auto`
  pass `QMAKE_APPLE_DEVICE_ARCHS` to `qmake -project`, after checking that
  Qt's `QtCore` holds the requested architectures (otherwise it stops
  with a message naming the Qt and its architectures). `build-caqt.sh`
  uses `-arch` when `faust2caqt -help` lists it. With an older
  `faust2caqt`, which builds for the machine it runs on, it writes a
  `.qmake.conf` with `QMAKE_APPLE_DEVICE_ARCHS` in its build directory
  instead: `qmake` reads `.qmake.conf` in the project directory and its
  parents, and `faust2caqt` creates its project in a temporary directory
  under the current one. Checked both ways; without either, the
  application is arm64 only.
- **Qt.** A universal application needs a universal Qt. The
  `setup-qt` action installs it with `aqtinstall` 3.3.0 (Qt's online
  packages for macOS are universal; Homebrew's Qt is arm64 only), in a
  virtual environment since the runner's Python refuses system-wide
  `pip` installs, and caches it like Faust. Default: Qt 6.8.3, the last
  open-source 6.8 LTS, which runs on macOS 12 and later; Qt 6.12 is
  built for macOS 14.4 at least (`minos 14.4` in `QtCore`), so the
  application would not start on older Macs. `macdeployqt` (run by
  `faust2caqt`) copies the frameworks and plugins into the application.
- **Checks.** `check_bundle_archs` (in `lib.sh`) requires the expected
  slices in every Mach-O file of the bundle: 18 files with Qt 6.12 (the
  binary, 7 frameworks, 10 plugins), not only the main binary. Then
  `codesign --verify --deep --strict` on the ad-hoc signature that
  `faust2caqt` applies.
- **Options.** Allowed: `-midi`, `-me`, `-nvoices <n>`, `-effect auto`,
  `-preset auto`, and the Faust options `-double -vec -dfs -fun -mcd -lv
  -vs <n> -ftz <n>`. Refused: `-opt` (runs `faustbench-llvm`, tunes for
  the runner's CPU); `-httpd`, `-qrcode`, `-osc` (link `libHTTPDFaust.a`,
  `libmicrohttpd`, `libOSCFaust.a`, built for the runner's architecture
  only); `-soundfile`, `-resample` (link Homebrew's `libsndfile` and
  `libsamplerate`, arm64 only and shared libraries users do not have);
  `-I`, `-effect <file>`, `-preset <dir>` (paths); `-nodeploy` (leaves Qt
  out of the application).
- **Environment.** The `faust2xxx` scripts are run without the variables
  of these scripts (`DSP`, `ARCHIVE`, `OPTIONS`, `NAME`, `ARCH`, `OUT`):
  `faust2caqt` appends to an `OPTIONS` variable it never resets, so
  `OPTIONS="-midi -nvoices 4"` in the workflow's environment made it pass
  `4` to `faust` as a file name; `faust2max6` reads `ARCH` likewise.
- **Size.** With Qt 6.12, `osc.app` takes 55 MB, 23 MB zipped: about 20
  compilations per day fit in the 500 MB artifact storage with a 7-day
  retention. Lower `retention-days` if needed.
- **Tested locally** (Qt 6.12.0 universal, Faust `78565936d`): `osc`
  universal and arm64 only, `withlib` through `archive` with
  `-midi -nvoices 4`, `-preset auto -me -double`, the refusals, and the
  zip extracted with `ditto -x -k` keeps the framework symlinks and a
  valid signature. Not tested: `-effect auto`, running the application.
- **On GitHub** (2026-11-04, Qt 6.8.3): `osc` and `withlib` (archive,
  `-midi -nvoices 4`) succeed in about 3 minutes, of which 1 min 45 to
  install Qt the first time and 50 s to compile; all 18 Mach-O files are
  universal, `QtCore` has `minos 12.0`, the application takes 54 MB,
  22.6 MB zipped. The Qt cache takes 1.14 GB of the 10 GB per
  repository; installing only the modules `faust2caqt` needs
  (`aqt install-qt ... --archives qtbase qtsvg`) would shrink it.
- **Download.** `gh run download` unpacks the zip without the symbolic
  links of the frameworks (`Versions/Current`, and the top-level links
  of each framework), so `codesign --verify --deep --strict` then fails
  on `QtWidgets.framework`. The zip itself is correct: downloaded with
  `GET .../actions/artifacts/<id>/zip` (what `githubOSX` does) and
  unpacked with `ditto -x -k`, the signature is valid. Max externals hold
  no symlinks and are not affected. The `faustosx` client must download
  the raw zip for applications.

## 10. The other macOS targets of faustservice

Inventory of faustservice (branch `server`, `makefiles/dockerosx`, which
the Dockerfile installs as `makefiles/osx`; checked 2026-11-04), with
what each one needs to move here.

### Already covered

| faustservice target | command | here |
| :--- | :--- | :--- |
| `max`, `max-mc`, `max-poly`, `max-poly-mc` | `faust2max6`, `-mc`, `-midi -nvoices 16` | `max.yml` |
| `coreaudio-qt`, `coreaudio-qt-midi` | `faust2caqt`, `-midi` | `caqt.yml` |

### Easy: only public headers to fetch

Implemented as `puredata.yml`, `supercollider.yml` and `csound.yml`
(`plot` to do), with `build-<target>.sh` on top of `lib.sh`:

- Pure Data: `m_pd.h` fetched from `raw.githubusercontent.com` at the tag
  given by the `pd` input (default `0.56-5`), as `PUREDATA_MACSDK`;
- SuperCollider: the `include/` directory of the sources, by a sparse
  checkout at the tag given by `sc` (default `Version-3.14.1`), as
  `SUPERCOLLIDER_HEADERS`; `faust2sc`, which writes the `.sc` class file,
  is a Ruby script and needs the runner's `ruby`;
- Csound: the `Headers` folder of `CsoundLib64.framework`, taken from the
  official universal installer of the release given by `csound` (default
  `6.18.1`: `hdiutil attach`, `pkgutil --expand-full`), cached; the
  repository's `include/` would lack `float-version.h` and `version.h`,
  which Csound generates at build time, and the `H/` headers that
  `csoundCore.h` includes. `faust2csound` has no `-arch`: it appends its
  flags to `CXXFLAGS` and compiles and links in one clang command, so
  `CXXFLAGS="-I<headers> -arch x86_64 -arch arm64"` makes it universal;
- `faust2puredata` and `faust2supercollider` (with `-universal`) build
  both architectures on an arm machine; for `arch=arm64` or `x86_64`,
  `thin_to_arch` (in `lib.sh`) extracts the requested one with
  `lipo -thin` and signs the file again;
- options refused: `-arch32`, `-arch64`, `-tosource` (Pure Data);
  `-soundfile` (Homebrew's libsndfile), `-d`, `-dm` (write to
  `/dev/tty`) for SuperCollider;
- tested locally: the refusals and `thin_to_arch`; compiling against the
  downloaded headers was refused by the local agent policy, so the first
  builds are the GitHub runs.

| target | script | needed on the runner | Intel + Apple Silicon |
| :--- | :--- | :--- | :--- |
| `puredata`, `puredata-poly` | `faust2puredata` (`-poly`) | `m_pd.h` from the Pure Data repository (`PUREDATA_MACSDK`); the external is linked with `-undefined suppress` | already: on an arm machine, so on `macos-15`, it builds both slices and merges them with `lipo` |
| `supercollider` | `faust2supercollider -noprefix` | the `plugin_interface`, `common` and `server` headers of the SuperCollider repository (`SUPERCOLLIDER_HEADERS`) | already on arm; `-universal` also exists |
| `csound` | `faust2csound` | the Csound headers (`CSOUND_MACSDK/Headers`); no library is linked (`-dynamiclib`) | no option: to check whether `CXXFLAGS="-arch x86_64 -arch arm64"` (appended to by the script) is enough, otherwise add `-arch` |
| `plot` | `faust2plot` | nothing (a command-line tool) | same as `csound`, through `CXXFLAGS`, to check |

faustservice splits two of them between Linux and the Mac today, and
`githubOSX` replaces only the Mac part, as `dockerOSX` does:

- `puredata`: `faust2puredata` runs on Linux first, where `faust2pd`
  writes the `.pd` patches (`faust2pd` is not installed on the runner),
  then on the Mac for the `.pd_darwin`;
- `supercollider`: the Mac builds the `.scx`, Linux writes the `.sc`
  class file (`-sn`).

### More work

- **`jack-qt` (`faust2jaqt`).** Implemented for Apple Silicon only, as
  `jaqt.yml` and `build-jaqt.sh`: Homebrew's JACK (`brew install jack`,
  arm64) provides `libjack` and its `pkg-config` file, and `faust2jaqt`
  builds for the machine it runs on. It is run with `-deploy` (not listed
  by its `-help`), without which `macdeployqt` is not run and the
  application would load Qt from the runner. `macdeployqt` also copies
  `libjack` into the application, while the JACK client library must
  match the user's JACK server: `build-jaqt.sh` removes it, changes the
  binary's reference to `@rpath/libjack.0.dylib` and adds the rpaths
  `/usr/local/lib` (JackOSX installer) and `/opt/homebrew/lib`
  (Homebrew), then signs again. Options: `-midi`, `-osc` (the arm64
  `libOSCFaust.a` of the runner's Faust is enough), `-nvoices <n>`,
  `-effect auto`, `-preset auto`, the Faust options; `-httpd`,
  `-qrcode`, `-soundfile`, `-resample` refused until tested. Two flags
  `faust2jaqt` does not give itself, needed when JACK and Faust are not
  in default directories (on the runner): the JACK include path, which
  it passes to qmake as `LIBS` only, goes in `CXXFLAGS`, and the path of
  `libOSCFaust.a` (`faust -libdir`) in `LFLAGS`; it appends its own flags
  to both. The proper fix is in `faust2jaqt`. Tested
  locally with Qt 6.12 and JACK 1.9.21 (JackOSX). Universal builds would
  need a universal `libjack` on the runner and `-arch` in `faust2jaqt`.
- **Unity `osx`, `ios`, `all` (`faust2unity`).** These makefiles still
  call `remoteOSX`, the SSH helper of the former Mac, while the
  Dockerfile installs only `dockerOSX`; its
  `rm -rf makefiles/unity/all makefiles/unity/osx` names paths that do
  not exist (the files are `Makefile.all` and `Makefile.osx`) and
  removes nothing. These three targets are therefore probably broken in
  production (not checked on the server). On macOS,
  `faust2osxiosunity -universal` exists; for iOS it compiles for
  `armv7 armv7s arm64`, and current Xcode versions no longer build
  `armv7`: that part needs fixing first.

### Blocked

- **`vst`, `vsti` (`faust2faustvst`).** It needs the VST2 SDK, which
  Steinberg no longer distributes and whose license forbids
  redistribution: it cannot be fetched by a workflow of a public
  repository. Options: keep these targets on `dockerOSX` (whose image
  presumably holds the SDK), drop them, or offer VST3 or AU plugins
  instead, for instance with `faust2juce`.

### Not concerned

`ios` (`faust2ios -xcodeproj`) and `vcvrack` (`faust2vcvrack -source`)
produce source projects on Linux, without a macOS binary.

### New: JUCE plugins (`faust2juce`)

faustservice's `juce` targets (`plug-in`, `application`, with `-midi`,
`-nvoices 16`, `-osc`) only return the project `faust2juce` writes, to
build with Projucer. This repository can return the built plugins:

- for plugins (without `-standalone` or `-llvm`), `faust2juce` also
  writes a `CMakeLists.txt` that builds them without Projucer, against a
  JUCE checkout (`-DJUCE_DIR`) or a JUCE it downloads (8.0.10 by
  default);
- `-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"` makes them universal;
- the formats are those of `faust2juce`: AU, VST3 and Standalone (JUCE
  builds AUv3 only with the Xcode generator). VST3 is also the way out
  for faustservice's `vst` / `vsti` targets, blocked by the VST2 SDK;
- `-standalone` produces a `.jucer` project only, which needs Projucer:
  refused at first, the Standalone format of the plugin build gives an
  application anyway.

Implemented as `juce.yml` and `scripts/build-juce.sh`:

- the `setup-juce` action clones the JUCE tag given by the `juce` input
  (default 8.0.10) and caches it;
- `build-juce.sh` runs `faust2juce`, moves the project out of the zipped
  folder (its `CMakeLists.txt` points to the runner's Faust include
  directory and could not be rebuilt elsewhere), configures it with
  `-DJUCE_DIR` and `CMAKE_OSX_ARCHITECTURES`, builds it, then signs each
  bundle ad hoc (JUCE leaves only the linker's signature of the binary),
  checks the slices of every Mach-O file and the signature;
- options: `-midi`, `-osc` (JUCE's own OSC module, no `libOSCFaust`),
  `-jsynth`, `-nvoices <n>`, `-disable-splash-screen`, the Faust options,
  and `-effect` / `-presets` followed by a file of the archive (or
  `auto`): `lib.sh` now accepts `.json` files in the archive and options
  whose value is a plain file name (`FILEARGS`). Refused: `-standalone`,
  `-llvm`, `-magic` (needs foleys_gui_magic), `-vst2sdkdir`,
  `-jucemodulesdir`, and `-soundfile` until it is tested with the CMake
  build;
- tested locally up to CMake only: building downloaded JUCE code here
  was refused by the local agent policy, so the first full build is the
  GitHub run.

### For every new target

- An options allow-list per script, as for Max and caqt: refuse the
  options that link libraries built for arm64 only and those taking a
  path.
- Stay on an arm64 runner (`macos-15`): on an Intel Mac, `faustoptflags`
  adds `-march=native`, which would tune the code for the runner's CPU.
- One workflow per script, `build-<target>.sh` on top of `lib.sh`, the
  SDK headers fetched at a pinned commit and cached when they are large.

### Order

1. `puredata`, `supercollider`: the scripts already build both
   architectures, only the headers are missing.
2. `csound`, `plot`.
3. `jack-qt`, after adding `-arch` to `faust2jaqt`.
4. Unity, together with the fix of its iOS part.
5. The decision on `vst` / `vsti` (VST3 through `faust2juce` is the
   candidate replacement).

JUCE plugins come first, before this order: they need no SDK beyond
JUCE itself and cover AU, VST3 and Standalone at once.

## 11. Milestones

1. Done: repository, `max.yml` with Faust built from `master-dev`, manual
   `workflow_dispatch` on `tests/osc.dsp`; `lipo -archs` lists
   `x86_64 arm64` and the external loads in Max.
2. Same external tested on an Intel Mac.
3. Done for Faust: cache saved right after the build, run time about 25 s
   with a warm cache. The Max SDK clone takes about 1 s and needs no cache.
4. Done: option validation and error log artifact. To do: the
   `scripts/faustosx` client.
5. faustservice integration (§7).
6. Signing and notarization, if the binaries are to be distributed.
7. `faust2caqt` (§9): done, universal applications built on GitHub with
   Qt 6.8.3. `-arch` added to `faust2caqt` in Faust, to commit to
   `master-dev`; `build-caqt.sh` uses it once there. To do: run the
   applications on an Apple Silicon and an Intel Mac, test `-effect auto`.
8. The other macOS targets of faustservice, in the order of §10.
