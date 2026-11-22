{
  description = "shiroinock の共通の GitHub Actions workflow と Renovate 設定、その検査";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-linux" "aarch64-linux" ] (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        tools = [
          pkgs.actionlint
          pkgs.shellcheck
          pkgs.zizmor
          pkgs.pinact
          pkgs.renovate
          pkgs.nodejs_24
        ];
        # Every check here runs offline, inside the Nix sandbox.
        lint = pkgs.writeShellApplication {
          name = "lint";
          runtimeInputs = tools;
          text = ''
            export HOME="''${TMPDIR:-/tmp}"
            echo "== actionlint (with shellcheck)"
            actionlint .github/workflows/*.yml templates/*.yml
            echo "== zizmor"
            zizmor --offline --no-progress .github/workflows templates
            echo "== pinact: actions pinned to a commit"
            pinact run --check
            echo "== renovate-config-validator"
            renovate-config-validator renovate/default.json templates/renovate.json renovate.json
            echo "== node --check"
            node --check scripts/merge-reservation.mjs
          '';
        };
      in
      {
        packages.lint = lint;
        apps.default = flake-utils.lib.mkApp { drv = lint; };

        checks.lint = pkgs.runCommand "lint" { } ''
          cp -r ${self}/. src
          chmod -R u+w src
          cd src
          ${pkgs.lib.getExe lint}
          touch $out
        '';

        devShells.default = pkgs.mkShell { packages = tools; };

        formatter = pkgs.nixfmt;
      }
    );
}
