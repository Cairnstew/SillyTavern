{ lib, pkgs }:

let
  inherit (lib) types;
in
rec {

  extensionSubmodule = { ... }: {
    options = {
      enable = lib.mkOption {
        type = types.bool;
        default = true;
        description = "Whether this extension is enabled. Disabled extensions are added to the disabledExtensions list.";
      };

      source = lib.mkOption {
        type = types.nullOr types.path;
        default = null;
        example = "pkgs.fetchFromGitHub { owner = \"user\"; repo = \"ext\"; rev = \"...\"; hash = \"...\"; }";
        description = ''
          Path or derivation for the extension source files.
          Use `pkgs.fetchFromGitHub` or `pkgs.fetchgit` for remote repos,
          or a local path for development.
          Must contain a valid `manifest.json`.
        '';
      };

      type = lib.mkOption {
        type = types.enum [ "global" "local" ];
        default = "global";
        description = ''
          Installation type: "global" for all users, "local" for the
          current user only. Only relevant with a source.
        '';
      };

      settings = lib.mkOption {
        type = types.attrs;
        default = { };
        example = {
          apiKey = "sk-...";
          someToggle = true;
          maxResults = 10;
        };
        description = ''
          Extension-specific settings injected into
          extension_settings.<name> in settings.json.
          These are deep-merged on each service start.
        '';
      };

      extraManifest = lib.mkOption {
        type = types.attrs;
        default = { };
        description = ''
          Extra fields to merge into the extension's manifest.json.
          Useful for overriding `loading_order`, `requires`, etc.
        '';
      };
    };
  };

  mkExtensionDirDerivation = extName: extCfg:
    let
      extDirName = extName;
    in
    pkgs.runCommand "sillytavern-ext-${extName}" { } (
      if extCfg.source != null then ''
        mkdir -p "$out/${extDirName}"
        cp -r ${extCfg.source}/* "$out/${extDirName}/"
        chmod -R +w "$out/${extDirName}"
        ${lib.optionalString (extCfg.extraManifest != { }) ''
          ${pkgs.jq}/bin/jq -s '.[0] * ${builtins.toJSON extCfg.extraManifest}' \
            "$out/${extDirName}/manifest.json" > "$out/${extDirName}/manifest.json.tmp" && \
          mv "$out/${extDirName}/manifest.json.tmp" "$out/${extDirName}/manifest.json"
        ''}
      '' else ''
        mkdir -p "$out"
      ''
    );

  mkExtensionsDir = extensions:
    let
      withSource = lib.filterAttrs (_: v: v.enable && v.source != null) extensions;
      dirs = lib.mapAttrsToList mkExtensionDirDerivation withSource;
    in
    pkgs.symlinkJoin {
      name = "sillytavern-third-party-extensions";
      paths = dirs;
    };

  mkExtensionsSetupScript = { dataDir, user, group, extensions, extSourceDir }:
    let
      enabled = lib.filterAttrs (_: v: v.enable) extensions;
      disabledNames = lib.attrNames (lib.filterAttrs (n: v: !v.enable) extensions);
      enabledWithSettings = lib.filterAttrs (_: v: v.settings != { }) enabled;
    in
    pkgs.writeShellScript "sillytavern-setup-extensions" ''
      set -e
      DATA_DIR="${dataDir}"
      EXT_SRC="${extSourceDir}"

      # Copy extension sources to third-party directory
      ${lib.optionalString (extSourceDir != "") ''
        TARGET_DIR="${toString pkgs.path}/public/scripts/extensions/third-party"
        # prettier-ignore
        if [ -d "$EXT_SRC" ] && [ "$(ls -A "$EXT_SRC")" ]; then
          mkdir -p "$TARGET_DIR"
          # prettier-ignore
          for ext_dir in "$EXT_SRC"/*/; do
            [ -d "$ext_dir" ] || continue
            ext_name="$(basename "$ext_dir")"
            target="$TARGET_DIR/$ext_name"
            rm -rf "$target"
            cp -r "$ext_dir" "$target"
            chown -R "${user}:${group}" "$target" 2>/dev/null || true
          done
        fi
      ''}

      # Apply extension enable/disable and settings
      if [ -d "$DATA_DIR" ]; then
        for userdir in "$DATA_DIR"/*/; do
          settings_file="$userdir/settings.json"
          [ -f "$settings_file" ] || continue

          ${lib.optionalString (disabledNames != []) ''
            # Update disabledExtensions list
            ${pkgs.jq}/bin/jq \
              --argjson disabled ${builtins.toJSON disabledNames} \
              '.extension_settings.disabledExtensions = (.extension_settings.disabledExtensions // []) + ($disabled - .extension_settings.disabledExtensions)' \
              "$settings_file" > "$settings_file.tmp" && \
            mv "$settings_file.tmp" "$settings_file"
          ''}

          ${lib.optionalString (enabledWithSettings != { }) (
            lib.concatStringsSep "\n" (lib.mapAttrsToList (name: ext: ''
              SETTINGS='${builtins.toJSON ext.settings}'
              ${pkgs.jq}/bin/jq \
                --argjson s "$SETTINGS" \
                '.extension_settings.${name} = (.extension_settings.${name} // {}) * $s' \
                "$settings_file" > "$settings_file.tmp" && \
              mv "$settings_file.tmp" "$settings_file"
            '') enabledWithSettings)
          )}

          chown "${user}:${group}" "$settings_file" 2>/dev/null || true
        done
      fi
    '';
}
