{
  description = "Claude Science for Nix, kept on the latest release automatically";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;
    systems = ["x86_64-linux"];
    forAllSystems = f:
      lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }));
  in {
    overlays.default = final: _: {
      claude-science = final.callPackage ./package.nix {};
    };

    packages = forAllSystems (pkgs: let
      claude-science = pkgs.callPackage ./package.nix {};
    in {
      inherit claude-science;
      default = claude-science;
      claude-science-unwrapped = claude-science.unwrapped;
      fhs-shell = claude-science.fhsShell;
    });

    apps = forAllSystems (pkgs: let
      pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-science;
      app = {
        type = "app";
        # With no arguments the binary prints help and exits 4; make
        # `nix run` start the app instead.
        program = toString (pkgs.writeShellScript "claude-science-run" ''
          if [ $# -eq 0 ]; then set -- serve; fi
          exec ${lib.getExe pkg} "$@"
        '');
        meta.description = pkg.meta.description;
      };
    in {
      default = app;
      claude-science = app;
    });

    # None of these execute the Claude Science binary.
    checks = forAllSystems (pkgs: {
      package = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-science;

      sources = pkgs.runCommandLocal "check-sources-json" {nativeBuildInputs = [pkgs.jq];} ''
        jq -e '
          (.version | test("^[0-9]+(\\.[0-9]+)*$"))
          and (.hashes | length > 0)
          and ([.hashes[] | test("^sha256-[A-Za-z0-9+/]{43}=$")] | all)
        ' ${./sources.json} > /dev/null
        touch $out
      '';

      shell-scripts = pkgs.runCommandLocal "check-shell-scripts" {nativeBuildInputs = [pkgs.shellcheck];} ''
        shellcheck ${./scripts/update.sh} ${./tests/inner-sandbox.sh} ${./tests/app-headless.sh}
        touch $out
      '';

      format = pkgs.runCommandLocal "check-format" {nativeBuildInputs = [pkgs.alejandra];} ''
        alejandra --check ${./flake.nix} ${./package.nix}
        touch $out
      '';
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = with pkgs; [jq curl shellcheck alejandra];
      };
    });
  };
}
