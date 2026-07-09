{
  description = "noctalia-plugins dev shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          python3
          luau # standalone runner for fixture-driven parser tests (no noctalia needed)
          jq
          fd
          ripgrep
        ];
      };
    };
}
