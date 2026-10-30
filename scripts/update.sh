#!/usr/bin/env bash
# Bump sources.json to the latest Claude Science release.
#
# Reads the upstream manifest; never downloads, hashes or runs the binary.
# `nix build` is what verifies the hash.
#
#   scripts/update.sh            update sources.json if a newer version exists
#   scripts/update.sh --check    exit 1 if an update is available, 0 otherwise
#   scripts/update.sh --dry-run  print what would change, write nothing
#   scripts/update.sh --force    also accept a version that isn't newer
#
# Needs: curl, jq, nix (for `nix hash convert`).
set -euo pipefail

base=https://downloads.claude.ai/claude-science
sources="$(cd "$(dirname "$0")/.." && pwd)/sources.json"

check=0 dry_run=0 force=0
for arg in "$@"; do
  case "$arg" in
    --check) check=1 ;;
    --dry-run) dry_run=1 ;;
    --force) force=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "$@" >&2; }
fetch() { curl -fsSL --retry 3 --retry-delay 5 "$1"; }

output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

manifest=$(fetch "$base/latest/manifest.json")
version=$(jq -r '.version' <<< "$manifest")
hex=$(jq -r '.sha256["linux-x64"]' <<< "$manifest")
build_date=$(jq -r '.buildDate // ""' <<< "$manifest")
sha8=$(jq -r '.sha8 // ""' <<< "$manifest")

if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  log "manifest has a malformed version: $version"; exit 1
fi
if ! [[ "$hex" =~ ^[0-9a-f]{64}$ ]]; then
  log "manifest has a malformed linux-x64 sha256: $hex"; exit 1
fi

current=$(jq -r '.version' "$sources")
output old "$current"
output new "$version"

if [ "$version" = "$current" ]; then
  log "up to date: $current"
  output updated false
  exit 0
fi

newest=$(printf '%s\n%s\n' "$current" "$version" | sort -V | tail -n1)
if [ "$newest" != "$version" ] && [ "$force" = 0 ]; then
  log "refusing to downgrade $current -> $version (use --force)"
  exit 1
fi

if [ "$check" = 1 ]; then
  log "update available: $current -> $version"
  exit 1
fi

# The per-version manifest is immutable; it must agree with `latest/`,
# otherwise we caught a release mid-rollout.
pinned_hex=$(fetch "$base/$version/manifest.json" | jq -r '.sha256["linux-x64"]')
if [ "$pinned_hex" != "$hex" ]; then
  log "latest/ and $version/ manifests disagree on the linux-x64 hash; try again later"
  exit 1
fi

sri=$(nix --extra-experimental-features nix-command hash convert --hash-algo sha256 --to sri "$hex")

log "updating: $current -> $version ($sri)"
if [ "$dry_run" = 1 ]; then
  output updated false
  exit 0
fi

tmp=$(mktemp)
jq --arg v "$version" --arg d "$build_date" --arg s "$sha8" --arg h "$sri" \
  '.version = $v | .buildDate = $d | .sha8 = $s | .hashes["x86_64-linux"] = $h' \
  "$sources" > "$tmp"
cat "$tmp" > "$sources"
rm "$tmp"
output updated true
