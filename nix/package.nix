{ lib, buildNpmPackage, src, version ? "1.18.0", npmDepsHash ? "sha256-jDySPn354gh1gFI8I2apGmXDxOz4d4STfJX+iFVFhdg=" }:

buildNpmPackage {
  pname = "sillytavern";
  inherit version src npmDepsHash;

  dontNpmBuild = true;

  postInstall = ''
    # Patch node-persist to skip subdirectories in readDirectory (EISDIR fix)
    patchFile="$out/lib/node_modules/sillytavern/node_modules/node-persist/src/local-storage.js"
    if [ -f "$patchFile" ]; then
        substituteInPlace "$patchFile" \
            --replace-fail "if (currentFile[0] !== '.') {" "if (currentFile[0] !== '.' && fs.statSync(path.join(this.options.dir, currentFile)).isFile()) {"
    fi

    mkdir -p $out/lib/node_modules/sillytavern/{backups,public/scripts/extensions/third-party}
  '';

  meta = {
    description = "LLM Frontend for Power Users";
    longDescription = ''
      SillyTavern is a user interface you can install on your computer (and Android phones) that allows you to interact with
      text generation AIs and chat/roleplay with characters you or the community create.

      This package makes a global installation, instead of a standalone installation according to the official tutorial.
      See the official documentation at https://docs.sillytavern.app for the context.
    '';
    homepage = "https://docs.sillytavern.app/";
    downloadPage = "https://github.com/SillyTavern/SillyTavern/releases";
    license = lib.licenses.agpl3Only;
    mainProgram = "sillytavern";
    platforms = lib.platforms.linux;
  };
}
