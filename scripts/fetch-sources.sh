#!/usr/bin/env bash
# Downloads every file in sources.lock into SOURCES_DIR and checks its SHA-256.
# With --offline nothing is downloaded: every file must already be present and match.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/lib.sh"
SRC="${SOURCES_DIR:-$ROOT/sources}"
OFFLINE=0
[[ "${1:-}" == "--offline" ]] && OFFLINE=1
mkdir -p "$SRC"

status=0
while read -r name version file sha url; do
  target="$SRC/$file"
  if [[ ! -f "$target" ]]; then
    if (( OFFLINE )); then
      echo "missing $file (offline)" >&2; status=1; continue
    fi
    curl --fail --location --silent --show-error --retry 3 -o "$target.part" "$url"
    mv "$target.part" "$target"
  fi
  actual="$(sha256sum "$target" | cut -d' ' -f1)"
  if [[ "$actual" != "$sha" ]]; then
    echo "hash mismatch for $file: expected $sha, got $actual" >&2; status=1
  else
    echo "ok $name $version"
  fi
done < <(lock_entries "$ROOT/sources.lock")
exit $status
