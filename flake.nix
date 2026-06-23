{
  description = "SillyTavern - LLM Frontend for Power Users";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self
    , nixpkgs
    , flake-utils
    , home-manager
    , ...
    } @ inputs:
    let
      # Systems supported by this flake
      systems = flake-utils.lib.defaultSystems;

      # Helper to evaluate nixpkgs for a given system
      nixpkgsFor = system:
        import nixpkgs {
          inherit system;
          overlays = [ self.overlays.default ];
        };

      # Build the SillyTavern package for a given system
      mkPkg = system:
        let pkgs = nixpkgsFor system;
        in pkgs.sillytavern;

    in
    {
      # ---- Overlay ----
      overlays.default = final: prev: {
        sillytavern = final.callPackage ./nix/package.nix {
          src = self;
          version = "1.18.0";
          npmDepsHash = "sha256-jDySPn354gh1gFI8I2apGmXDxOz4d4STfJX+iFVFhdg=";
        };
      };

      # ---- NixOS Module ----
      nixosModules = {
        sillytavern = import ./nix/module.nix;
        default = { config, lib, pkgs, ... }: {
          imports = [ self.nixosModules.sillytavern ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
      };

      # ---- Home Manager Module ----
      homeManagerModules = {
        sillytavern = import ./nix/home-manager.nix;
        default = { config, lib, pkgs, ... }: {
          imports = [ self.homeManagerModules.sillytavern ];
          nixpkgs.overlays = [ self.overlays.default ];
        };
      };
    }
    // flake-utils.lib.eachSystem systems (system:
    let
      pkgs = nixpkgsFor system;
    in
    {
      # ---- Package ----
      packages = {
        sillytavern = pkgs.sillytavern;
        default = pkgs.sillytavern;
      };

      # ---- Apps (nix run) ----
      apps = {
        sillytavern = flake-utils.lib.mkApp { drv = pkgs.sillytavern; };
        default = flake-utils.lib.mkApp { drv = pkgs.sillytavern; };
      };

      # ---- Dev Shell ----
      devShells.default = pkgs.mkShell {
        packages = with pkgs; [
          nodejs_22
          git
        ];
      };
    });
}
