#!/usr/bin/env bash
# Runs inside the FHS namespace (via the fhs-shell package). Imitates the
# bubblewrap sandbox Claude Science starts for conda envs and MCP connectors:
# same system binds as the app (taken from the 0.1.71 binary), no /run, no
# /etc/static, a scrubbed environment. Doesn't run the app itself.
#
#   tests/inner-sandbox.sh <conda-env-prefix> <nixpkgs-source-path>
#
# The env must be a conda-forge env with python and openssl (created outside
# with micromamba); its binaries use the /lib64 loader like any non-Nix binary.
# The nixpkgs path (this flake's locked input) lets `nix develop` on the
# fixture flake run without network. A nix-daemon must be running on the host.
set -euo pipefail

if [ $# -ne 2 ]; then
  echo "usage: $0 <conda-env-prefix> <nixpkgs-source-path>" >&2
  exit 2
fi
env_prefix=$1
nixpkgs=$2
fixture=$(cd "$(dirname "$0")/fixtures/devshell" && pwd)
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
  --proc /proc --dev /dev --tmpfs /tmp)
for p in /usr /lib /lib64 /bin /sbin /opt /nix; do
  sandbox+=(--ro-bind-try "$p" "$p")
done
for p in passwd group nsswitch.conf ld.so.cache ld.so.conf ld.so.conf.d ssl \
  ca-certificates pki localtime mime.types alternatives default bash.bashrc fonts; do # the app's list
  sandbox+=(--ro-bind-try "/etc/$p" "/etc/$p")
done
sandbox+=(--ro-bind "$env_prefix" /env --ro-bind "$fixture" /fixture --)

echo "--- Imitated inner sandbox"
# The app binds no resolv.conf/hosts (its sandboxed processes go through its
# approval proxy), so resolve outside and test certificate validation inside.
host=pypi.org
ip=$(curl -fsS -o /dev/null -w '%{remote_ip}' "https://$host/simple/")
check "/run is absent" "${sandbox[@]}" /bin/bash -c '! test -e /run/current-system'
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

echo "--- Nix inside the imitated sandbox"
# A fresh derivation each run, so the daemon really builds something.
probe="derivation { name = \"probe\"; system = \"x86_64-linux\"; builder = \"/bin/sh\"; args = [\"-c\" \"echo $$-$(date +%s%N) > \$out\"]; }"
check "/usr/bin/python3 runs" "${sandbox[@]}" /usr/bin/python3 -c 'import sys, ssl, sqlite3'
check "nix reaches the host daemon" "${sandbox[@]}" nix store info
check "nix evaluates" "${sandbox[@]}" nix eval --expr '1 + 1'
check "nix builds through the daemon" "${sandbox[@]}" nix build --no-link --print-out-paths --impure --expr "$probe"
check "nix-build dispatches through the wrapper" "${sandbox[@]}" nix-build --no-out-link -E "$probe"
check "nix-shell dispatches through the wrapper" "${sandbox[@]}" nix-shell --version
check "nixpkgs# resolves to the pinned registry entry" "${sandbox[@]}" bash -c \
  "nix flake metadata --json nixpkgs | grep -qF '\"path\":\"$nixpkgs\"'"
check "nix develop runs a flake devShell" "${sandbox[@]}" nix develop --no-write-lock-file \
  --override-input nixpkgs "path:$nixpkgs" path:/fixture -c hello

exit $fail
