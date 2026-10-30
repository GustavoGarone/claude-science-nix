#!/usr/bin/env bash
# Runs inside the FHS namespace (via the fhs-shell package). Imitates the
# bubblewrap sandbox Claude Science starts for conda envs and MCP connectors:
# same system binds as the app (taken from the 0.1.71 binary), no /run, no
# /etc/static, a scrubbed environment. Doesn't run the app itself.
#
#   tests/inner-sandbox.sh <conda-env-prefix>
#
# The env must be a conda-forge env with python and openssl (created outside
# with micromamba); its binaries use the /lib64 loader like any non-Nix binary.
set -euo pipefail

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
  --proc /proc --dev /dev --tmpfs /tmp)
for p in /usr /lib /lib64 /bin /sbin /opt /nix; do
  sandbox+=(--ro-bind-try "$p" "$p")
done
for p in passwd group nsswitch.conf ld.so.cache ld.so.conf ld.so.conf.d ssl \
  ca-certificates pki localtime mime.types alternatives default bash.bashrc fonts; do # the app's list
  sandbox+=(--ro-bind-try "/etc/$p" "/etc/$p")
done
sandbox+=(--ro-bind "$env_prefix" /env --)

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

exit $fail
