{
  # Used by tests/inner-sandbox.sh with --override-input nixpkgs pointing at
  # this repo's locked nixpkgs, so nothing is fetched to evaluate it (hello
  # still comes from the binary cache if it isn't in the store).
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
  in {
    devShells.x86_64-linux.default = pkgs.mkShellNoCC {packages = [pkgs.hello];};
  };
}
