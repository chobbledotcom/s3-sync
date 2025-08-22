{
  description = "S3 bucket sync tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            awscli2
            jq
            rclone
            bash
          ];
        };

        packages.default = pkgs.writeScriptBin "sync-s3-buckets" ''
          #!${pkgs.bash}/bin/bash
          exec ${pkgs.bash}/bin/bash ${./sync-s3-buckets.sh} "$@"
        '';
      });
}