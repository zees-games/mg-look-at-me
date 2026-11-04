#!/bin/bash
# Publishes this game's pack (id mg-look-at-me). Host addons come from the server (--host-addons).
#   tools/publish.sh [--version V | --bump patch] [--site URL --token-file F --dry-run ...]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec "$HERE/../dot-cloud/tools/publish_pack.sh" publish --source "$HERE" --id mg-look-at-me \
    --host-addons "$HERE/../dot-server-deploy/addons.lock" --exclude-dir screenshots \
    --lock "$HERE/content.lock.json" "$@"
