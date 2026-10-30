{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  writeShellScript,
  writeShellScriptBin,
  makeDesktopItem,
  bash,
  coreutils,
  findutils,
  bubblewrap,
  socat,
  procps,
  ripgrep,
  cacert,
  zlib,
  openssl,
  bzip2,
  curl,
  xz,
  libxml2,
  zstd,
  attr,
  acl,
  libsodium,
  libssh,
  util-linux,
  python3,
  git,
  # Extra packages for the FHS /usr, e.g. `pkgs: [pkgs.R pkgs.quarto]`.
  extraPkgs ? (_: []),
}: let
  sources = lib.importJSON ./sources.json;
  inherit (sources) version;
  system = stdenv.hostPlatform.system;

  unwrapped = stdenvNoCC.mkDerivation {
    pname = "claude-science-unwrapped";
    inherit version;

    # Always the immutable per-version URL; `latest/` changes under the hash.
    src = fetchurl {
      url = "https://downloads.claude.ai/claude-science/${version}/linux-x64";
      hash = sources.hashes.${system} or (throw "claude-science: unsupported system ${system}");
    };

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    # Bun keeps the app's JS payload appended to the ELF; leave the file
    # byte-for-byte intact. The FHS env provides /lib64/ld-linux-x86-64.so.2,
    # so no patchelf either: skip fixup entirely.
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      install -Dm755 $src $out/bin/claude-science
      runHook postInstall
    '';

    meta = meta // {description = meta.description + " (unwrapped binary)";};
  };

  # Entry point inside the FHS namespace. The binary's own self-updater can't
  # replace a store path, so turn it off: `serve` checks
  # process.argv.includes("--no-auto-update"), so position doesn't matter.
  # DISABLE_AUTOUPDATER (Claude Code's variable) is not read by this binary.
  entrypoint = writeShellScript "claude-science-entrypoint" ''
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    export CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
    bin=${unwrapped}/bin/claude-science

    # Find the subcommand, skipping global flags (and the values they take).
    cmd=
    skip=0
    for arg in "$@"; do
      if [ "$skip" = 1 ]; then skip=0; continue; fi
      case "$arg" in
        --data-dir|--config|--assets-root) skip=1 ;;
        -*) ;;
        *) cmd=$arg; break ;;
      esac
    done

    case "$cmd" in
      serve)
        exec "$bin" "$@" --no-auto-update
        ;;
      update)
        for arg in "$@"; do
          if [ "$arg" = --check ]; then exec "$bin" "$@"; fi
        done
        echo "claude-science: this install is managed by Nix; update the claude-science-nix flake input instead." >&2
        exit 1
        ;;
    esac
    exec "$bin" "$@"
  '';

  # The app finds bwrap on PATH, so this shim stands in for it and adds
  # read-only binds of the NixOS paths its sandbox never binds: system and
  # per-user profiles (on the sandbox's fixed PATH via
  # /run/current-system/sw/bin) and /etc/static, which /etc symlinks point
  # into. The real sandbox call rebuilds /etc with `--tmpfs /etc`, so there
  # the binds go just before the `--` ending bwrap's options, after the app's
  # own; other calls (capability probes) get them first, where they are
  # harmless. Seccomp and network setup run after `--` and are untouched.
  # This relies on the shape of the app's argv (checked on 0.1.71: options
  # inline, `--tmpfs /etc` as two words, first `--` ends them); if a release
  # changes it, /etc/static links dangle again, and the debug log shows why.
  # Everything bound is in /nix/store, which the sandbox already reads.
  # Adapted from leuflatworm/nix-claude-science (MIT).
  bwrapShim = lib.hiPrio (writeShellScriptBin "bwrap" ''
    # Debug log, opt-in by creating the file yourself (the app clears the
    # environment, so no variable reaches here). argv may hold proxy secrets.
    log=/tmp/claude-science-bwrap.log
    if [ -f "$log" ] && [ -O "$log" ] && [ ! -L "$log" ]; then
      { printf '%q ' "$@"; printf '\n'; } >> "$log" 2>/dev/null || true
    fi
    extra=()
    for p in /run/current-system /run/opengl-driver /etc/profiles /etc/static; do
      extra+=(--ro-bind-try "$p" "$p")
    done
    tmpfs_etc=0
    prev=
    for a in "$@"; do
      if [ "$prev" = --tmpfs ] && [ "$a" = /etc ]; then tmpfs_etc=1; break; fi
      prev=$a
    done
    args=()
    if [ "$tmpfs_etc" = 1 ]; then
      spliced=0
      for a in "$@"; do
        if [ "$spliced" = 0 ] && [ "$a" = -- ]; then
          args+=("''${extra[@]}" --)
          spliced=1
        else
          args+=("$a")
        fi
      done
      if [ "$spliced" = 0 ]; then args=("''${extra[@]}" "$@"); fi
    else
      args=("''${extra[@]}" "$@")
    fi
    exec ${bubblewrap}/bin/bwrap "''${args[@]}"
  '');

  # Runs a command in a project's Nix dev shell inside the app's sandbox,
  # where nix itself can't reach the daemon (seccomp blocks AF_UNIX sockets).
  # It sources the environment nix-direnv already built on the host, which
  # only refers to /nix/store, and refuses one older than the flake.
  nixEnvRun = writeShellScriptBin "nix-env-run" ''
    if [ $# -lt 3 ] || [ "$2" != -- ]; then
      echo "usage: nix-env-run <project-dir> -- <command> [args...]" >&2
      exit 2
    fi
    dir=$1
    shift 2
    orig=$PWD
    cd "$dir" || exit 1
    rc=
    for f in .direnv/flake-profile-*.rc; do
      if [ -f "$f" ] && { [ -z "$rc" ] || [ "$f" -nt "$rc" ]; }; then rc=$f; fi
    done
    if [ -z "$rc" ]; then
      echo "nix-env-run: no nix-direnv environment in $dir/.direnv; run 'direnv allow' there in a terminal outside Claude Science" >&2
      exit 1
    fi
    # Like nix-direnv's own check, by mtime, but also over every .nix file a
    # flake may import.
    newer=$(${findutils}/bin/find . \( -name .git -o -name .direnv -o -name node_modules \) -prune \
      -o \( -name flake.lock -o -name '*.nix' \) -newer "$rc" -print -quit)
    if [ -n "$newer" ]; then
      echo "nix-env-run: $dir/$rc is older than $newer; run 'direnv reload' in $dir in a terminal outside Claude Science" >&2
      exit 1
    fi
    # The shellHook runs in the project dir and may print; keep stdout for
    # the command, and the caller's cwd for its relative paths.
    # shellcheck disable=SC1090
    source "$rc" >&2
    cd "$orig" || exit 1
    exec "$@"
  '';

  # The app's inner bubblewrap sandbox binds /usr /lib /lib64 /bin /sbin /opt
  # /nix and a list of /etc files, but never /run or /etc/static. An FHS
  # namespace puts bash at /bin/bash, the glibc loader at /lib64, and these
  # libraries in /usr/lib + /etc/ld.so.cache, all of which it binds through.
  targetPkgs = pkgs:
    [
      unwrapped
      bwrapShim
      nixEnvRun
      python3 # /usr/bin/python3 is the default [conda].operon_python_bin
      git
      bash
      coreutils
      bubblewrap
      socat
      procps
      ripgrep
      cacert
      stdenv.cc.cc.lib # libstdc++ for the `sharp` module
      # Same set as programs.nix-ld's defaults, for conda/micromamba binaries.
      zlib
      openssl
      bzip2
      curl
      xz
      libxml2
      zstd
      attr
      acl
      libsodium
      libssh
      util-linux
    ]
    ++ extraPkgs pkgs;

  # buildFHSEnv links /etc/ssl/certs to /.host-etc/ssl/certs, which dangles
  # inside the app's sandbox (it binds /etc/ssl but not /.host-etc). Put a
  # tmpfs over /etc/ssl and bind real files instead. The host bundle is
  # resolved at launch so security.pki extras are kept; cacert is the fallback.
  caBundle = ''"$(${coreutils}/bin/readlink -e /etc/ssl/certs/ca-certificates.crt || echo ${cacert}/etc/ssl/certs/ca-bundle.crt)"'';

  fhsArgs = {
    inherit version targetPkgs;
    extraBwrapArgs = [
      "--tmpfs /etc/ssl"
      "--ro-bind ${caBundle} /etc/ssl/certs/ca-certificates.crt"
      "--ro-bind ${caBundle} /etc/ssl/certs/ca-bundle.crt"
    ];
    # `serve --detached` and the app's self-restart leave a daemon running
    # after the launcher exits; --die-with-parent would kill it.
    dieWithParent = false;
  };

  desktopItem = makeDesktopItem {
    name = "claude-science";
    desktopName = "Claude Science";
    comment = meta.description;
    exec = "claude-science-launch";
    categories = ["Science"];
    terminal = false;
  };

  fhsShell = buildFHSEnv (fhsArgs
    // {
      pname = "claude-science-fhs-shell";
      runScript = "bash";
    });

  meta = {
    description = "Claude Science, Anthropic's research workbench for life science";
    homepage = "https://claude.com/product/claude-science";
    license = lib.licenses.unfree;
    sourceProvenance = [lib.sourceTypes.binaryNativeCode];
    mainProgram = "claude-science";
    platforms = ["x86_64-linux"];
  };
in
  buildFHSEnv (fhsArgs
    // {
      pname = "claude-science";
      runScript = entrypoint;

      # Desktop launcher: reopen the UI if the daemon is up, else start it.
      extraInstallCommands = ''
        cat > $out/bin/claude-science-launch <<EOF
        #!${bash}/bin/sh
        $out/bin/claude-science open || exec $out/bin/claude-science serve --detached
        EOF
        chmod +x $out/bin/claude-science-launch
        install -Dm644 ${desktopItem}/share/applications/claude-science.desktop \
          $out/share/applications/claude-science.desktop
      '';

      passthru = {inherit unwrapped fhsShell;};
      inherit meta;
    })
