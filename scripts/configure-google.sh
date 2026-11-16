#!/usr/bin/env bash
# Writes Resources/google.json (git-ignored) with the Google iOS OAuth client ID used for
# Google Drive backup.
#   ./scripts/configure-google.sh [IOS_CLIENT_ID]
# The client ID comes from the argument, $DEDPAD_IOS_CLIENT_ID, or Config/ios-client-id.txt.
# Without one, the app builds fine and shows "Google Drive backup isn't set up".
set -euo pipefail
cd "$(dirname "$0")/.."
CLIENT_ID="${1:-${DEDPAD_IOS_CLIENT_ID:-$(cat Config/ios-client-id.txt 2>/dev/null || true)}}"
CLIENT_ID="$(echo "$CLIENT_ID" | tr -d '[:space:]')"
if [ -n "$CLIENT_ID" ] && [[ "$CLIENT_ID" != *.apps.googleusercontent.com ]]; then
  echo "That doesn't look like an OAuth client ID (it should end in .apps.googleusercontent.com)." >&2
  exit 1
fi
if [ -n "$CLIENT_ID" ]; then
  mkdir -p Config
  echo "$CLIENT_ID" > Config/ios-client-id.txt
fi
python3 -I - "$CLIENT_ID" > Resources/google.json <<'PY'
import json, sys
print(json.dumps({"iosClientId": sys.argv[1]}, indent=2))
PY
echo "Wrote Resources/google.json (iOS client: ${CLIENT_ID:-<missing>})"
