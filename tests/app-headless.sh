#!/usr/bin/env bash
# Exercises the packaged app without logging in: version, detached daemon,
# health endpoint, auto-update handling. Runs the real binary.
#
#   HOME=<scratch dir> tests/app-headless.sh <path to bin/claude-science>
set -uo pipefail

app=$1
port=18731
fail=0
check() {
  local name=$1; shift
  if out=$("$@" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"; printf '     %s\n' "$out"; fail=1
  fi
}
info() {
  local name=$1; shift
  echo "info $name:"
  "$@" 2>&1 | sed 's/^/     /'
  echo "     (exit ${PIPESTATUS[0]})"
}

expected=$(jq -r .version "$(dirname "$0")/../sources.json")
check "--version reports $expected" bash -c "'$app' --version | grep -qF '$expected'"
check "update is refused" bash -c "! '$app' update < /dev/null"
info "update --check" timeout 60 "$app" update --check < /dev/null
info "no arguments" timeout 15 "$app" < /dev/null

check "serve --detached returns" timeout 120 "$app" serve --no-browser --detached --port "$port" < /dev/null
healthy=0
for _ in $(seq 60); do
  if curl -fsS "http://127.0.0.1:$port/health" > /dev/null 2>&1; then healthy=1; break; fi
  sleep 2
done
check "daemon answers /health after the launcher exited" test "$healthy" = 1
info "status" timeout 30 "$app" status < /dev/null
info "sandbox status" timeout 60 "$app" sandbox status < /dev/null
info "mcp-env-check" timeout 300 "$app" mcp-env-check < /dev/null
info "daemon log: update/engine/sandbox lines" bash -c "timeout 30 '$app' logs < /dev/null | grep -iE 'updat|engine|prefetch|sandbox|bwrap|error' | cut -c1-300 | head -60"
check "stop" timeout 60 "$app" stop < /dev/null
check "daemon is gone after stop" bash -c "sleep 3; ! curl -fsS http://127.0.0.1:$port/health"
# Desktop launcher path: does 'open' start a daemon when none is running?
info "open without a running daemon" env BROWSER=true timeout 60 "$app" open < /dev/null
info "status after open" bash -c "timeout 30 '$app' status < /dev/null | head -5"
info "cleanup stop" timeout 60 "$app" stop < /dev/null
check "nothing installed to ~/.local/bin" bash -c "! ls '$HOME/.local/bin' 2>/dev/null | grep -q ."

exit $fail
