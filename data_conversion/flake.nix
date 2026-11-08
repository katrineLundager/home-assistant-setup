{
  description = "Python environment for dataconversion";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      python = pkgs.python313;
      pythonEnv = python.withPackages (
        ps: with ps; [
          pandas
          pandas-stubs
          numpy
          openpyxl
        ]
      );
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          pythonEnv
        ];
      };
    };
}
