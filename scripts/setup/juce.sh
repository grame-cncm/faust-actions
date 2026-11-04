#!/bin/bash
# Fetch JUCE at tag $JUCE_VERSION into $JUCEDIR.
set -euo pipefail
: "${JUCE_VERSION:?}" "${JUCEDIR:?}"
[[ "$JUCE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+)?$ ]] || { echo "::error::invalid JUCE version '$JUCE_VERSION'"; exit 1; }
git clone -q --depth 1 --branch "$JUCE_VERSION" https://github.com/juce-framework/JUCE "$JUCEDIR"
