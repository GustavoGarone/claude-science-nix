{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  buildFHSEnv,
  writeShellScript,
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

  # The app's inner bubblewrap sandbox binds /usr /lib /lib64 /bin /sbin /opt
  # /nix and a list of /etc files, but never /run or /etc/static. An FHS
  # namespace puts bash at /bin/bash, the glibc loader at /lib64, and these
  # libraries in /usr/lib + /etc/ld.so.cache, all of which it binds through.
  targetPkgs = _: [
    unwrapped
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
  ];

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
