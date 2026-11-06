# pkgs/sillytavern/mkchar.nix
#
# `sillytavern-mkchar` — the guided character-card generator.
#
# A thin wrapper around `scripts/st_mkchar.py`, which is STDLIB-ONLY on
# purpose (no `requests`, no `Pillow`): the only runtime input here is
# `python3`, so a third-party import in the script is a failure this
# derivation would not catch at build time. The script's own header documents
# why each dependency was avoided.
#
# The script is referenced by ABSOLUTE store path (`${...}/st_mkchar.py`),
# not copied: it is read-only either way, and a copy would drift from the
# tested file (`nix-tests/test_mkchar.py` imports the working-tree script).
{ lib, python3, writeShellApplication }:

writeShellApplication {
  name = "sillytavern-mkchar";
  runtimeInputs = [ python3 ];
  text = ''
    exec ${lib.getExe python3} ${../../scripts/st_mkchar.py} "$@"
  '';
  meta = with lib; {
    description = "Guided TavernCard v2 generator for SillyTavern (Ollama / llama.cpp / any OpenAI-compatible endpoint)";
    homepage = "https://github.com/SillyTavern/SillyTavern";
    license = licenses.agpl3Plus;
    platforms = platforms.unix;
    mainProgram = "sillytavern-mkchar";
  };
}
