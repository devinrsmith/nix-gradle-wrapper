# Dev-only flake for this repo's own tests/CI (`nix flake check`). Does
# NOT affect how consumers use gradle-wrapper.nix -- see README.md, they
# pull this repo in with `flake = false` precisely so they get the raw
# source tree without evaluating this file or its inputs at all.
{
  description = "nix-gradle-wrapper: vendor and isolate a Gradle wrapper's distribution under Nix (dev flake for this repo's own tests)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      checks = forEachSystem (pkgs: {
        unit = import ./tests/unit.nix { inherit pkgs; };
        integration = import ./tests/integration.nix { inherit pkgs self; };
      });
    };
}
