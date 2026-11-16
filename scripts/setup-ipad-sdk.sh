#!/usr/bin/env bash
# One-time: sign in to Apple and install the iOS SDK from Xcode.xip.
#   ./scripts/setup-ipad-sdk.sh /path/to/Xcode.xip
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f toolchain/env.sh ] && source toolchain/env.sh
XIP="${1:?Usage: $0 /path/to/Xcode.xip}"
xtool auth                      # choose "Password" for a free Apple ID
xtool sdk install "$XIP"        # unpacks the iOS SDK into ~/.swiftpm/swift-sdks
swift sdk list
echo "Done. Plug in the iPad and run ./scripts/run-on-ipad.sh"
