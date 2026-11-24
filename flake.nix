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
          pkgs.ast-grep
        ];
        # The shared ast-grep rules, run on the current directory. `--fix` applies the fixes.
        # Rule ids listed in .github/static-rules-off (one per line, # starts a comment) are off.
        rules = pkgs.writeShellApplication {
          name = "rules";
          runtimeInputs = [ pkgs.ast-grep ];
          text = ''
            off=()
            if [ -f .github/static-rules-off ]; then
              while IFS= read -r line || [ -n "$line" ]; do
                id="''${line%%#*}"
                id="''${id//[[:space:]]/}"
                [ -n "$id" ] && off+=("--off=$id")
              done < .github/static-rules-off
            fi
            if [ "''${1:-}" = --fix ]; then
              shift
              set -- --update-all "$@"
            fi
            exec ast-grep scan --config ${./static-rules}/sgconfig.yml "''${off[@]}" "$@"
          '';
        };
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
            node --check scripts/harvest-findings.mjs
            echo "== shellcheck: scripts"
            shellcheck -s bash scripts/*.sh
            echo "== ast-grep: the shared rules and their tests"
            if find static-rules/rules -name '*.yml' | grep -q .; then
              ast-grep test --config static-rules/sgconfig.yml --skip-snapshot-tests
            else
              echo "ルールはまだ無い"
            fi
          '';
        };
        # Common settings for the owner's repositories, with templates/ of the same version.
        repo-baseline = pkgs.writeShellApplication {
          name = "repo-baseline";
          runtimeInputs = [
            pkgs.gh
            pkgs.jq
            pkgs.coreutils
            pkgs.gnugrep
            pkgs.gawk
          ];
          # op (1Password CLI) comes from PATH when it is there; without it the secret is skipped.
          bashOptions = [ ];
          text = ''
            export TEMPLATES_DIR="''${TEMPLATES_DIR:-${./templates}}"
            ${builtins.readFile ./scripts/repo-baseline.sh}
          '';
        };
        # Checks the hashes of fixed-output derivations (npmDepsHash and the like) against the
        # lockfiles; `--fix` writes the right ones. nix itself comes from PATH.
        nix-hashes = pkgs.writeShellApplication {
          name = "nix-hashes";
          runtimeInputs = [
            pkgs.git
            pkgs.gnused
            pkgs.gawk
            pkgs.gnugrep
            pkgs.coreutils
          ];
          bashOptions = [
            "nounset"
            "pipefail"
          ];
          text = builtins.readFile ./scripts/nix-hashes.sh;
        };
        repo-new = pkgs.writeShellApplication {
          name = "repo-new";
          runtimeInputs = [
            pkgs.gh
            pkgs.jq
            pkgs.coreutils
            pkgs.git
            repo-baseline
          ];
          bashOptions = [ ];
          text = builtins.readFile ./scripts/repo-new.sh;
        };
      in
      {
        packages.lint = lint;
        packages.repo-baseline = repo-baseline;
        packages.repo-new = repo-new;
        apps.repo-baseline = flake-utils.lib.mkApp { drv = repo-baseline; };
        apps.repo-new = flake-utils.lib.mkApp { drv = repo-new; };
        # Called by .github/workflows/pinact.yml in other repositories, at the version locked here.
        packages.pinact = pkgs.pinact;
        # Called by .github/workflows/pinact.yml in other repositories, and locally.
        packages.rules = rules;
        # Called by .github/workflows/nix-hashes.yml in other repositories, and locally.
        packages.nix-hashes = nix-hashes;
        apps.nix-hashes = flake-utils.lib.mkApp { drv = nix-hashes; };
        apps.rules = flake-utils.lib.mkApp { drv = rules; };
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
