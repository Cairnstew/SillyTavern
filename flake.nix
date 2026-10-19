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
#   inputs.sillytavern.url = "github:Cairnstew/nixos-sillytavern";
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
        # The package itself is pure MIT-ish/AGPL JS with no unfree
        # dependencies. Enabling `allowUnfree` here would be convenient and
        # wrong: it would silently change the licence posture of every consumer
        # who imports this flake. A consumer who needs unfree adds it to their
        # own nixpkgs.
        config = { };
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
      source = lib.cleanSourceWith {
        src = ./.;
        name = "sillytavern-source";
        filter = import ./pkgs/sillytavern/filter.nix { inherit lib; };
      };

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
              # `pkgs.eslint`, not `pkgs.nodePackages.eslint`: nodePackages was
              # removed from nixpkgs; the packages moved to the top level.
              eslint

              # The activation-time helpers. scripts/st_seed_users.py uses only
              # the standard library, so this is for running the tests and for
              # anyone extending it — not a runtime dependency of the module.
              python3
              python3Packages.pytest

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
              echo "  npm ci                    install the app's dependencies"
              echo "  npm start                 run the server against ./data"
              echo "  python3 -m pytest tests/  the seeder's tests"
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
          default = {
            type = "app";
            program = "${self.packages.${system}.sillytavern}/bin/sillytavern";
          };
          seeder = {
            type = "app";
            program = "${pkgs.python3} ${./scripts/st_seed_users.py}";
          };
        }
      );
    };
}
