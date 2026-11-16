#!/usr/bin/env bash
# Build, sign, install and launch dedpad on the USB-connected iPad.
#   ./scripts/run-on-ipad.sh          (same as: xtool dev)
#   ./scripts/run-on-ipad.sh build    (build only)
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional: a local toolchain folder with an env.sh that puts swift and xtool on PATH.
[ -f toolchain/env.sh ] && source toolchain/env.sh
# The app bundles Resources/google.json; create an empty one if Drive backup isn't configured.
[ -f Resources/google.json ] || ./scripts/configure-google.sh >/dev/null
exec xtool dev "$@"
