#!/usr/bin/env bash
# shellcheck disable=SC2016 # single-quoted commands expand inside the sandbox
# Runs inside the FHS namespace (via the fhs-shell package). Imitates the
# bubblewrap sandbox Claude Science starts for conda envs and MCP connectors:
# same system binds as the app (taken from the 0.1.71 binary), a fresh /etc,
# no /run, a scrubbed environment, and `bwrap` resolved from PATH, so it goes
# through this package's shim like the app's calls do. It can't imitate the
# app's seccomp filter. Doesn't run the app itself.
#
#   tests/inner-sandbox.sh <conda-env-prefix>
#
# The env must be a conda-forge env with python and openssl (created outside
# with micromamba); its binaries use the /lib64 loader like any non-Nix binary.
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "usage: $0 <conda-env-prefix>" >&2
  exit 2
fi
env_prefix=$1
fail=0
check() {
  local name=$1; shift
  if out=$("$@" 2>&1); then
    echo "ok   $name"
  else
    echo "FAIL $name"; printf '     %s\n' "$out"; fail=1
  fi
}

echo "--- FHS layout"
check "/bin/bash exists" test -x /bin/bash
check "/lib64 loader exists" test -e /lib64/ld-linux-x86-64.so.2
check "/etc/ld.so.cache is a real file" bash -c '[ -f /etc/ld.so.cache ] && [ ! -L /etc/ld.so.cache ]'
check "CA bundle is a real file" bash -c '[ -f /etc/ssl/certs/ca-certificates.crt ] && [ ! -L /etc/ssl/certs/ca-certificates.crt ]'
check "libstdc++ is in the ld cache" bash -c 'ldconfig -p | grep -q libstdc++.so.6'

sandbox=(bwrap --unshare-all --share-net --die-with-parent
  --clearenv --setenv PATH /usr/bin:/bin:/run/current-system/sw/bin --setenv HOME /tmp
  --proc /proc --dev /dev --tmpfs /tmp --tmpfs /etc)
for p in /usr /lib /lib64 /bin /sbin /opt /nix; do
  sandbox+=(--ro-bind-try "$p" "$p")
done
for p in passwd group nsswitch.conf ld.so.cache ld.so.conf ld.so.conf.d ssl \
  ca-certificates pki localtime mime.types alternatives default bash.bashrc fonts; do # the app's list
  sandbox+=(--ro-bind-try "/etc/$p" "/etc/$p")
done
# A project with a fake nix-direnv cache, for nix-env-run.
proj=$(mktemp -d)
trap 'rm -rf "$proj"' EXIT
mkdir "$proj/.direnv"
mkdir "$proj/nix"
touch -d '2 days ago' "$proj/flake.nix" "$proj/flake.lock" "$proj/nix/shell.nix"
printf 'export PROBE_VAR=from-rc\necho shell-hook-output\n' > "$proj/.direnv/flake-profile-0.rc"
touch -d '1 day ago' "$proj/.direnv/flake-profile-0.rc"
sandbox+=(--ro-bind "$env_prefix" /env --bind "$proj" /proj --)

echo "--- Imitated inner sandbox"
# The app binds no resolv.conf/hosts (its sandboxed processes go through its
# approval proxy), so resolve outside and test certificate validation inside.
host=pypi.org
ip=$(curl -fsS -o /dev/null -w '%{remote_ip}' "https://$host/simple/")
check "/run/user is absent" "${sandbox[@]}" /bin/bash -c '! test -e /run/user'
check "/bin/bash -c runs" "${sandbox[@]}" /bin/bash -c 'echo hi | grep -q hi'
check "curl verifies TLS" "${sandbox[@]}" curl -fsS -o /dev/null --resolve "$host:443:$ip" "https://$host/simple/"
check "conda-forge python runs" "${sandbox[@]}" /env/bin/python -c 'import sys; print(sys.version)'
check "python stdlib C extensions load" "${sandbox[@]}" /env/bin/python -c 'import ssl, sqlite3, zlib, ctypes'
check "python verifies TLS with the system CA bundle" "${sandbox[@]}" /env/bin/python -c "
import socket, ssl
ctx = ssl.create_default_context(cafile='/etc/ssl/certs/ca-certificates.crt')
with socket.create_connection(('$ip', 443), timeout=30) as s:
    with ctx.wrap_socket(s, server_hostname='$host') as t:
        print(t.version())"

echo "--- bwrap shim and nix-env-run"
check "/usr/bin/python3 runs" "${sandbox[@]}" /usr/bin/python3 -c 'import sys, ssl, sqlite3'
if [ -e /run/current-system ] && [ -e /etc/static ]; then
  check "shim binds the system profile read-only" "${sandbox[@]}" /bin/bash -c \
    'test -x /run/current-system/sw/bin/bash && ! touch /run/current-system/x 2>/dev/null'
  check "shim binds /etc/static after the app's --tmpfs /etc" "${sandbox[@]}" /bin/bash -c \
    'test -d /etc/static && test -n "$(ls /etc/static)"'
else
  echo "skip shim binds (not NixOS)"
fi
check "a capability probe through the shim still runs" bwrap --unshare-user --disable-userns --dev-bind / / -- /usr/bin/true
check "nix-env-run sources the nix-direnv environment" "${sandbox[@]}" /bin/bash -c \
  '[ "$(nix-env-run /proj -- /bin/bash -c "echo \$PROBE_VAR")" = from-rc ]'
check "nix-env-run keeps the caller's cwd" "${sandbox[@]}" /bin/bash -c \
  'cd /tmp && [ "$(nix-env-run /proj -- pwd)" = /tmp ]'
touch "$proj/nix/shell.nix"
check "nix-env-run refuses an environment older than an imported .nix file" "${sandbox[@]}" /bin/bash -c \
  '! nix-env-run /proj -- true'
touch -d '2 days ago' "$proj/nix/shell.nix"
touch "$proj/flake.lock"
check "nix-env-run refuses an environment older than flake.lock" "${sandbox[@]}" /bin/bash -c \
  '! nix-env-run /proj -- true'

exit $fail
