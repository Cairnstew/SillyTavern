# flake.nix
#
# A Nix flake for NixOS packaging of SillyTavern, built from THIS repository's
# source (unlike nixos-projectzomboid-servers, which fetches the game it wraps).
#
# Outputs:
#   nixosModules.sillytavern   the module
#   homeModules.sillytavern   the Home Manager half
#   packages.<system>.sillytavern
#   packages.<system>.default       the same package; what `nix flake check` builds
#   overlays.default          adds pkgs.sillytavern
#   lib                       the shared renderers
#   devShells.default         nodejs + npm + python3 + the app's toolchain
#   checks.<system>.*         see lib/tests.nix
#   apps / formatter
#
# Consumed as a flake input:
#
#   inputs.sillytavern.url = "github:Cairnstew/SillyTavern";
#   nixpkgs.overlays = [ inputs.sillytavern.overlays.default ];
#   imports = [ inputs.sillytavern.nixosModules.sillytavern ];
#
# or without the overlay:
#
#   services.sillytavern-nixos.package = inputs.sillytavern.packages.${system}.sillytavern;
{
  description = "NixOS module and package for SillyTavern, built from this repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # nixpkgs' `lib`, for the things that are system-independent: the source
      # filter, the YAML/env renderers, the tests. Using `nixpkgs.lib` rather
      # than `pkgsFor system`.lib means the source and the test harness are
      # evaluated exactly once, rather than once per system — which also avoids
      # `pkgsFor "x86_64-linux".lib`, where Nix parses the `.lib` selection
      # against the string argument and hands the filter a string.
      inherit (nixpkgs) lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;
      pkgsFor = system: import nixpkgs {
        inherit system;
        # `allowUnfree` is enabled for the FLAKE'S OWN package set only.
        #
        # The SillyTavern package itself is pure MIT-ish/AGPL JS with no unfree
        # dependencies, so this does not change it. It is here for
        # `pkgs.llama-cpp-cuda`, whose CUDA runtime is unfree, so the backend
        # module and its checks can evaluate the variant this project targets.
        #
        # It does NOT change a consumer's licence posture: a consumer who
        # imports `nixosModules.*` keeps their own `nixpkgs.config`. Only the
        # outputs built from this `pkgsFor` — this flake's packages, checks and
        # devShells — see it.
        config = {
          allowUnfree = true;
        };
      };

      # The application source: THIS flake's own tree.
      #
      # `./.` — not `self`. Inside a flake, `self` is the flake's OUTPUT attrset
      # (nixosModules, packages, …), not its source directory, so passing it as
      # `src` hands `cleanSource` an attrset and fails with "expected a set but
      # found a string" from deep inside the filter, which says nothing about the
      # real mistake. `./.` resolves to the flake's source tree, already
      # stripped of `.git` by Nix itself.
      #
      # The filter then drops `node_modules`, `dist` and `result`; see
      # pkgs/sillytavern/filter.nix for why each is load-bearing.
      #
      # `lib/source.nix` is the single definition of that filtered source, and
      # it is shared with `overlay.nix`, `modules/sillytavern.nix` and
      # `default.nix` so that all four build the SAME package. See that file
      # for what happens when they drift apart.
      source = import ./lib/source.nix { inherit lib; } ./.;

      mkOverlay =
        final: prev:
        {
          # `src` is passed EXPLICITLY rather than inherited under another name.
          # `callPackage` fills any argument it recognises from the package set,
          # and this derivation's argument is called `src` — which nixpkgs also
          # defines (now `simple-revision-control`). Not passing it overrides
          # that fill, and not passing it correctly fails with "The \"src\"
          # package has been renamed to \"simple-revision-control\"" — a
          # confusing error that says nothing about the real problem.
          sillytavern = final.callPackage ./pkgs/sillytavern {
            src = source;
            version = (final.lib.importJSON ./version.json).version;
          };
        };

      overlay = mkOverlay;
    in
    {
      overlays = {
        default = overlay;
        sillytavern = overlay;
      };

      # The non-flake entry point, reused as the flake's module so there is
      # exactly one definition of each. See default.nix for why that file's top
      # level is a plain attrset.
      nixosModules = {
        sillytavern = ./modules/sillytavern.nix;
        # The inference backend. Separate on purpose: it has its own lifetime
        # and resource profile, and neither service should force the other on.
        # See modules/llama.nix.
        llama-cpp = ./modules/llama.nix;
        default = self.nixosModules.sillytavern;
      };

      homeModules = {
        sillytavern = ./modules/home.nix;
        default = self.homeModules.sillytavern;
      };

      lib = import ./lib { inherit lib; };

      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          sillytavern = (overlay pkgs pkgs).sillytavern;

          # `nix flake check` builds `packages.<system>.default` and NOTHING
          # else in `packages`. Without this attribute it built no package at
          # all, and every check in `lib/tests.nix` is evaluation-time or pure
          # Python — so a broken `installPhase`, a stale `nodeModulesHash`, or a
          # `fetchgit` that has drifted all passed the suite green.
          #
          # That is not hypothetical: `overlay.nix` failed to EVALUATE
          # (callPackage injected `pkgs.src`) for exactly as long as this
          # attribute was missing, and nothing caught it. One line here is what
          # makes the suite able to.
          default = self.packages.${system}.sillytavern;
        }
        // (import ./lib/tests.nix { inherit lib nixpkgs; }).packages pkgs
      );

      checks = forAllSystems (system: (import ./lib/tests.nix { inherit lib nixpkgs; }).checks (pkgsFor system));

      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            name = "sillytavern-dev";

            packages = with pkgs; [
              # The app's own toolchain. `npm` comes bundled with nodejs, and
              # there is no top-level `npm` attribute in nixpkgs to add.
              nodejs

              # The activation-time helpers. scripts/st_seed_users.py uses only
              # the standard library, so this is for running the tests and for
              # anyone extending it — not a runtime dependency of the module.
              python3
              python3Packages.pytest

              # The task runner the justfile targets. `just develop <cmd>`
              # runs a command in this shell via `nix develop --command`,
              # which is how the justfile reaches everything below.
              just

              # Nix linting and formatting. NOT wired to the `formatter`
              # output — see the note there — so these are opt-in tools.
              statix
              deadnix
              alejandra
              shellcheck

              git
              jq
              yq-go
              curl
              ripgrep
            ];

            shellHook = ''
              export SILYTAVERN_SOURCE="$PWD"
              echo "sillytavern dev shell — node $(node --version), python $(python3 --version)"
              echo
              echo "  just --list              every task; the justfile is the entry point"
              echo "  just develop '<cmd>'     run a command in this shell (non-interactive)"
              echo "  just test                the seeder's Python suites"
              echo "  just test-live           build a server, boot it, assert over HTTP"
              echo "  just check               every flake check — what CI runs"
              echo "  just audit               the config-surface coverage audit"
              echo
              echo "eslint is NOT in this shell on purpose: nixpkgs ships eslint 10, which"
              echo "refuses to read the repo's .eslintrc.cjs. The lint recipe uses the"
              echo "version package.json pins (v8), so run 'just npm-ci' first."
              echo
              echo "To run the module against this tree, point the package at it:"
              echo
              echo "  services.sillytavern-nixos.package = pkgs.sillytavern.overrideAttrs (o: { src = $PWD; });"
              echo
            '';
          };
        }
      );

      # `nix flake check` runs the formatter check, and this project has no
      # Nix formatter configured (no nixpkgs-fmt / alejandra in the tree), so
      # `formatter` is deliberately absent rather than pointing at something
      # that would rewrite every file.
      #
      # The project's own formatter is prettier via `npm run lint:fix`, which
      # only covers the JavaScript.

      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          # `meta` is not optional in practice: `nix flake check` warns for
          # every app that omits it, and the warning is noise that trains people
          # to ignore the output of the one command that gates this project.
          default = {
            type = "app";
            program = "${self.packages.${system}.sillytavern}/bin/sillytavern";
            meta.description = "Run the SillyTavern server straight from the store";
          };
          seeder = {
            type = "app";
            program = "${pkgs.python3} ${./scripts/st_seed_users.py}";
            meta.description = "Seed SillyTavern accounts into a data root";
          };
        }
      );
    };
}
