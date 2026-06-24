{ lib, pkgs }:

let
  inherit (lib) types;
in
{

  characterSubmodule = { ... }: {
    options = {
      url = lib.mkOption {
        type = types.str;
        example = "https://files.catbox.moe/abc123.png";
        description = "URL to download the character card from. Supports PNG (V2 spec) and JSON formats.";
      };

      fileName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "my-character.png";
        description = "Filename to save as. Defaults to the basename of the URL.";
      };

      rewriteExisting = lib.mkOption {
        type = types.bool;
        default = false;
        description = "If true, re-download even if the file already exists.";
      };
    };
  };

  lorebookSubmodule = { ... }: {
    options = {
      url = lib.mkOption {
        type = types.str;
        example = "https://files.catbox.moe/def456.json";
        description = "URL to download the lorebook from. Expects a JSON file with an entries array.";
      };

      fileName = lib.mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "my-world.json";
        description = "Filename to save as. Defaults to the basename of the URL.";
      };

      rewriteExisting = lib.mkOption {
        type = types.bool;
        default = false;
        description = "If true, re-download even if the file already exists.";
      };
    };
  };

  mkContentSetupScript = { dataDir, user, group, characters, lorebooks }:
    pkgs.writeShellScript "sillytavern-setup-content" ''
      set -e
      DATA_DIR="${dataDir}"

      if [ ! -d "$DATA_DIR" ]; then
        echo "Data directory $DATA_DIR does not exist yet, skipping content download"
        exit 0
      fi

      for userdir in "$DATA_DIR"/data/*/; do
        [ -d "$userdir" ] || continue
        case "''${userdir##*/}" in _*) continue;; esac
        USER_DIR="$userdir"

        ${lib.optionalString (characters != { }) ''
          CHAR_DIR="$USER_DIR/characters"
          mkdir -p "$CHAR_DIR"
          cd "$CHAR_DIR"

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: char: ''
            CHAR_NAME="${lib.optionalString (char.fileName != null) char.fileName (builtins.baseNameOf char.url)}"
            CHAR_TARGET="$CHAR_DIR/$CHAR_NAME"
            if [ ! -f "$CHAR_TARGET" ] || ${lib.boolToString char.rewriteExisting}; then
              echo "  Downloading character '${name}' from ${char.url}"
              ${pkgs.curl}/bin/curl -fsSL '${char.url}' -o "$CHAR_TARGET"
              chown "${user}:${group}" "$CHAR_TARGET" 2>/dev/null || true
            else
              echo "  Character '${name}' already exists, skipping"
            fi
          '') characters)}
        ''}

        ${lib.optionalString (lorebooks != { }) ''
          WORLD_DIR="$USER_DIR/worlds"
          mkdir -p "$WORLD_DIR"
          cd "$WORLD_DIR"

          ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: book: ''
            WORLD_NAME="${lib.optionalString (book.fileName != null) book.fileName (builtins.baseNameOf book.url)}"
            WORLD_TARGET="$WORLD_DIR/$WORLD_NAME"
            if [ ! -f "$WORLD_TARGET" ] || ${lib.boolToString book.rewriteExisting}; then
              echo "  Downloading lorebook '${name}' from ${book.url}"
              ${pkgs.curl}/bin/curl -fsSL '${book.url}' -o "$WORLD_TARGET"
              chown "${user}:${group}" "$WORLD_TARGET" 2>/dev/null || true
            else
              echo "  Lorebook '${name}' already exists, skipping"
            fi
          '') lorebooks)}
        ''}
      done
    '';
}
