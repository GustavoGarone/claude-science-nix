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

### Nix inside the sandbox

Commands the agent runs see only that FHS `/usr`, plus `/nix`. `/run/current-system`, `/etc/profiles/per-user/*` and `~/.nix-profile` are not mounted, so host packages are not on its `PATH`. Use Nix shells instead: the FHS has a `nix` wrapper (also `nix-shell`, `nix-build`, …) that talks to the host's nix-daemon through `/nix/var/nix/daemon-socket` and turns on flakes, because `/etc/nix` isn't visible there either. So the agent can run a project's own pinned toolchain:

```bash
nix develop ~/projetos/my-project -c Rscript analysis.R
nix shell nixpkgs#samtools -c samtools --version
```

- Grant the project folder to Claude Science, read-write if its `shellHook` writes files.
- Locked flake inputs already in the store need no network. New downloads go through the app's network approval proxy.
- `nixpkgs#…` resolves to the nixpkgs this package was built with, which is already in the store, because the host's registry in `/etc/nix` isn't visible in the sandbox. The wrapper replaces the global registry, so other global ids (`flake-utils#…`, `templates#…`) don't resolve there; use full refs such as `github:numtide/flake-utils`. Where `/etc/nix/registry.json` is visible, as in `fhs-shell`, its pins win.
- The wrapper uses the daemon only when `/nix/var/nix/daemon-socket/socket` exists. Without a daemon, `nix` can't build inside the app's sandbox, where the store is read-only.

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

That `pkgs` also supplies the `nix` the wrapper runs (override with `nixPackage`). It must speak the host daemon's protocol, which a nixpkgs from the last couple of years does.

If `extraPkgs` contains files that are also in the base set, `extraPkgs` wins, except for the `nix` wrapper, which keeps priority so `/usr/bin/nix` still works in the sandbox. Putting another Python there also changes `/usr/bin/python3`, which the app's control kernel runs.

### SSH

The sandbox gets neither `~/.ssh` nor `SSH_AUTH_SOCK`: the app strips that variable, and `/run` isn't mounted. The app's own SSH remote-compute connections are made by the daemon, outside that sandbox, using your ssh-agent. Start the daemon from a session where `SSH_AUTH_SOCK` is set. A desktop session normally sets it, so the desktop launcher works.

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
- `tests/inner-sandbox.sh`: inside the FHS env, imitates the app's inner sandbox (its bind list, no `/run`, scrubbed env) and checks `/bin/bash`, TLS validation with curl and with a conda-forge Python, that the conda-forge Python loads its C extensions, `/usr/bin/python3`, and that `nix` reaches the daemon, builds, and runs `nix develop` on a fixture flake. It doesn't run the app. Without the FHS env every check fails.
- `tests/app-headless.sh`: runs the app without logging in: `--version`, `serve --detached`, `/health`, `stop`, refused `update`, nothing written to `~/.local/bin`.

Not covered (needs a logged-in session): conda environments created by the app, MCP connectors, `sharp` rendering.
