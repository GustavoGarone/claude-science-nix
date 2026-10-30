{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  writeShellScript,
  writeText,
  runCommandLocal,
  makeDesktopItem,
  bash,
  coreutils,
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
  nix,
  path,
  # Must speak the host nix-daemon's protocol; nixpkgs' default does.
  nixPackage ? nix,
  # Extra packages for the FHS /usr, e.g. `pkgs: [pkgs.R pkgs.quarto]`.
  extraPkgs ? (_: []),
  # What `nixpkgs#…` resolves to inside the app's sandbox.
  nixpkgsPath ? path,
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

  # Inside the app's inner sandbox there is no /etc/nix and nix.db is
  # read-only, but /nix (with the daemon socket) is bound: talk to the host
  # daemon and enable flakes from the environment. With no system registry
  # there, `nixpkgs#…` would go to the global registry over the network, so
  # point the global registry at a nixpkgs that is already in the store. Host
  # registries (/etc/nix, ~/.config/nix) still take precedence where visible.
  flakeRegistry = writeText "claude-science-flake-registry.json" (builtins.toJSON {
    version = 2;
    flakes = [
      {
        from = {
          type = "indirect";
          id = "nixpkgs";
        };
        to = {
          type = "path";
          path = "${nixpkgsPath}";
        };
      }
    ];
  });
  nixScript = writeShellScript "nix" ''
    if [ -z "''${NIX_REMOTE+x}" ] && [ -S /nix/var/nix/daemon-socket/socket ]; then
      export NIX_REMOTE=daemon
    fi
    export NIX_CONFIG="extra-experimental-features = nix-command flakes
    flake-registry = ${flakeRegistry}''${NIX_CONFIG:+
    $NIX_CONFIG}"
    export NIX_SSL_CERT_FILE=''${NIX_SSL_CERT_FILE:-/etc/ssl/certs/ca-certificates.crt}
    exec -a "''${0##*/}" ${nixPackage}/bin/nix "$@"
  '';
  # nix dispatches on argv[0], so every name is a link to the same script.
  # hiPrio: a `nix` in extraPkgs must not replace it in the FHS /usr/bin.
  nixWrapper = lib.hiPrio (runCommandLocal "claude-science-nix-wrapper" {} ''
    mkdir -p $out/bin
    for n in nix nix-build nix-shell nix-store nix-instantiate nix-env nix-collect-garbage; do
      ln -s ${nixScript} $out/bin/$n
    done
  '');

  # The app's inner bubblewrap sandbox binds /usr /lib /lib64 /bin /sbin /opt
  # /nix and a list of /etc files, but never /run or /etc/static. An FHS
  # namespace puts bash at /bin/bash, the glibc loader at /lib64, and these
  # libraries in /usr/lib + /etc/ld.so.cache, all of which it binds through.
  targetPkgs = pkgs:
    [
      unwrapped
      nixWrapper
      python3 # /usr/bin/python3 is the default [conda].operon_python_bin
      git # flakes in git repos
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
