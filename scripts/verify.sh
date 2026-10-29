#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift test -j 1
swift build -c release -j 1
FATX_BIN_DIR="$(swift build -c release --show-bin-path)"
python3 scripts/integration.py "$FATX_BIN_DIR/fatx"
python3 scripts/browser-integration.py "$FATX_BIN_DIR/fatxbridge"
if [ "$(uname -s)" = Darwin ]; then ./scripts/build-app.sh; fi
