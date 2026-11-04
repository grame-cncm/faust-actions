#!/bin/bash
# Install Qt $QT_VERSION for macOS (universal binaries, "clang_64") in
# $ROOT/$QT_VERSION/macos with aqtinstall. aqtinstall goes into its own
# virtual environment: the runner's Python refuses system-wide pip
# installs (PEP 668).
set -euo pipefail
: "${QT_VERSION:?}" "${ROOT:?}"
[[ "$QT_VERSION" =~ ^6\.[0-9]+\.[0-9]+$ ]] || { echo "::error::invalid Qt version '$QT_VERSION'"; exit 1; }
python3 -m venv "$RUNNER_TEMP/aqt-venv"
"$RUNNER_TEMP/aqt-venv/bin/pip" install -q aqtinstall==3.3.0
"$RUNNER_TEMP/aqt-venv/bin/aqt" install-qt mac desktop "$QT_VERSION" clang_64 --outputdir "$ROOT"
