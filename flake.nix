{
    description = "nng dev env";

    inputs = {
        nixpkgs.url = "github:NixOS/nixpkgs";
        flake-utils.url = "github:numtide/flake-utils";
    };

    outputs = { self, nixpkgs, flake-utils }: flake-utils.lib.eachDefaultSystem(
        system:
        let
            pkgs = nixpkgs.legacyPackages.${system};
            commonShellHook = ''
                eval "$(starship init bash)"
            '';
            darwinShellHook = pkgs.lib.optionalString pkgs.stdenv.isDarwin ''
                export SDKROOT="$(${pkgs.xcrun}/bin/xcrun --show-sdk-path)"
            '';
          in {
            devShells.default = pkgs.mkShell {
              buildInputs = [
                pkgs.zsh
                pkgs.starship
                pkgs.bintools
              ];
              shellHook = commonShellHook + darwinShellHook;
            };
        }
    );
}
