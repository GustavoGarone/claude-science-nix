# claude-science-nix

Nix flake for [Claude Science](https://claude.com/product/claude-science), Anthropic's research workbench for life science. It tracks the latest upstream release automatically. Linux x86_64 only.

Claude Science is proprietary (`meta.license = unfree`); you need `allowUnfree`. The packaging code here is MIT.

## Usage

```bash
nix run github:GustavoGarone/claude-science-nix   # runs `serve` when given no arguments
```

As a flake input:

```nix
inputs.claude-science-nix = {
  url = "github:GustavoGarone/claude-science-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};

# Home Manager or environment.systemPackages:
inputs.claude-science-nix.packages.${pkgs.stdenv.hostPlatform.system}.default
```

or through `overlays.default`, which adds `pkgs.claude-science`.

Outputs: `packages.x86_64-linux.{default, claude-science, claude-science-unwrapped, fhs-shell}`, `overlays.default`, `apps.x86_64-linux.default`.

## NixOS notes

Claude Science runs conda environments and MCP connectors in its own bubblewrap sandbox. That sandbox binds `/usr`, `/lib`, `/lib64`, `/bin`, `/nix` and a few `/etc` files, but not `/run` or `/etc/static`, so on a plain NixOS system it finds no `/bin/bash`, no dynamic loader and a broken CA bundle.

This package runs the app inside a `buildFHSEnv` namespace, so those paths exist as real FHS paths and pass through to the inner sandbox:

- `/bin/bash`, coreutils, bubblewrap, socat, procps and ripgrep are on the FHS `PATH`.
- The `/lib64` glibc loader and a library set matching `programs.nix-ld`'s defaults (plus libstdc++) are in `/usr/lib` and `/etc/ld.so.cache`. nix-ld is not involved.
- `/etc/ssl/certs/ca-certificates.crt` is a bind-mounted real file: the host bundle, so `security.pki` additions are kept, with nixpkgs' `cacert` as a fallback.

No NixOS module or host configuration is needed. It does require unprivileged user namespaces, which NixOS allows by default.

To inspect the namespace, use `nix run .#fhs-shell`.

`/usr/bin/python3` is included because the app's control kernel uses it by default (`[conda].operon_python_bin`).

### Host packages and Nix shells inside the sandbox

The app finds `bwrap` on `PATH`, so the FHS puts a shim in front of it, adapted from [leuflatworm/nix-claude-science](https://github.com/leuflatworm/nix-claude-science) (MIT). The shim adds read-only binds of `/run/current-system`, `/etc/profiles`, `/etc/static` and `/run/opengl-driver` to the app's sandbox. System packages are then on the sandbox's fixed `PATH` (it includes `/run/current-system/sw/bin`), and links into those paths resolve. `/etc/profiles/per-user/$USER/bin` (NixOS-integrated Home Manager) is visible but not on `PATH`. Nothing under your home is added, so `~/.nix-profile` stays unreachable. The shim leaves the app's seccomp filter and network setup alone. Everything it binds lives in `/nix/store`, which the sandbox can already read, so sandboxed code sees nothing new, only by more convenient paths. That includes the generated NixOS `/etc` in `/etc/static`; files kept outside the store, such as `/etc/shadow` or ssh host keys, stay hidden. The shim recognizes the app's real sandbox call by its argv shape, checked on 0.1.71. If a release changes that shape, use the debug log below to see why the binds are missing.

`nix` itself can't work in there: the app's seccomp filter blocks creating any Unix socket, so it can't reach the nix-daemon. We don't lift that. Daemon access would let sandboxed code build fixed-output derivations, which fetch any URL from outside the app's network approval, and write to the store. Instead, prepare a project's dev shell outside the sandbox with [nix-direnv](https://github.com/nix-community/nix-direnv), and run commands in it with `nix-env-run`:

```bash
# in a terminal, once and after each flake change (nix-direnv also keeps it from being garbage-collected):
cd ~/projetos/my-project && direnv allow    # or: direnv reload
# inside Claude Science:
nix-env-run ~/projetos/my-project -- Rscript analysis.R
```

`nix-env-run` sources the newest `.direnv/flake-profile-*.rc`, which refers only to `/nix/store`. It refuses one older than `flake.lock` or any `.nix` file in the project. Like nix-direnv's own check, this goes by modification time: a change to some other file the flake reads goes unnoticed, and a checkout that only touches a file can ask for an unnecessary reload. Grant the project folder to Claude Science, read-write if its `shellHook` writes files.

To see the sandbox calls, create the log file yourself: `install -m600 /dev/null /tmp/claude-science-bwrap.log`. The shim appends each call's arguments while the file exists, and the file grows with every call. Delete it as soon as you're done, since the arguments can include the proxy's credentials.

For tools that should always be on `PATH`, without a Nix shell, add them to the FHS:

```nix
claude-science.override {extraPkgs = pkgs: [pkgs.R pkgs.quarto];}
# or, built with a project's own nixpkgs (its lock's versions):
inputs.claude-science-nix.lib.mkClaudeScience pkgs {extraPkgs = p: [p.R];}
```

`mkClaudeScience` uses the `pkgs` you pass, and Claude Science is unfree, so that `pkgs` needs `allowUnfree`. A flake's `nixpkgs.legacyPackages.${system}` doesn't have it; import nixpkgs yourself:

```nix
pkgs = import nixpkgs {
  inherit system;
  config.allowUnfree = true; # or allowUnfreePredicate for just "claude-science-unwrapped"
};
```

If `extraPkgs` contains files that are also in the base set, `extraPkgs` wins, except for the `bwrap` shim, which keeps priority. Putting another Python there also changes `/usr/bin/python3`, which the app's control kernel runs.

### SSH

The sandbox gets neither `~/.ssh` nor `SSH_AUTH_SOCK`: the app strips that variable, and `/run/user` (where the agent socket lives) isn't mounted. The app's own SSH remote-compute connections are made by the daemon, outside that sandbox, using your ssh-agent. Start the daemon from a session where `SSH_AUTH_SOCK` is set. A desktop session normally sets it, so the desktop launcher works.

## Updates

The built-in self-updater is disabled: the wrapper adds `--no-auto-update` to `serve` and refuses `update` (`update --check` still works). Note that `DISABLE_AUTOUPDATER` is not read by this binary. To be thorough, you can also set this in `~/.claude-science/config.toml`:

```toml
[update]
auto_update = false
```

New releases arrive through this repo. Every 6 hours, `.github/workflows/update.yml` reads `https://downloads.claude.ai/claude-science/latest/manifest.json`, writes the version and hash to `sources.json` (cross-checked against the immutable per-version manifest), builds, and pushes to `main` only if the build passes. A failed run opens or comments on a single "Auto-update failed" issue. `flake.lock` is bumped weekly the same way.

Manually:

```bash
nix develop -c scripts/update.sh [--check|--dry-run|--force]
```

## Tests

CI (`.github/actions/verify`, run on every push, PR and auto-update) does:

- `nix flake check`: build, `sources.json` schema, shellcheck, formatting.
- `tests/inner-sandbox.sh`: inside the FHS env, imitates the app's inner sandbox (its bind list, no `/run`, scrubbed env) and checks `/bin/bash`, TLS validation with curl and with a conda-forge Python, that the conda-forge Python loads its C extensions, `/usr/bin/python3`, the binds the `bwrap` shim adds (on NixOS), and `nix-env-run`. It can't imitate the app's seccomp filter. It doesn't run the app. Without the FHS env every check fails.
- `tests/app-headless.sh`: runs the app without logging in: `--version`, `serve --detached`, `/health`, `stop`, refused `update`, nothing written to `~/.local/bin`.

Not covered (needs a logged-in session): conda environments created by the app, MCP connectors, `sharp` rendering.
