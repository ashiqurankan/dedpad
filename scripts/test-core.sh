#!/usr/bin/env bash
# Runs the DedpadCore unit tests on Linux (no iOS SDK needed).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f toolchain/env.sh ] && source toolchain/env.sh
DEDPAD_CORE_ONLY=1 swift test --scratch-path .build/core "$@"
