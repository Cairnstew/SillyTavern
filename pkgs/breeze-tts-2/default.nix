# pkgs/breeze-tts-2/default.nix
#
# `breeze-server` and friends, built from source.
#
# ── Why this is pinned here rather than an input to the upstream flake ────────
#
# Upstream ships a Nix flake and a NixOS module on a feature branch
# (`feat/nix`). This repository's policy is that a backend module owns its
# options, its unit, its checks and its resource guards — the llama.cpp module
# sets that precedent. Vendoring the derivation (source is Apache-2.0) keeps
# `nix flake check` able to evaluate the package on any checkout, and keeps the
# module's `package` option from silently changing when a branch moves.
#
# The two source submodules are fetched separately because a flake source tree
# never contains submodule content. Their revisions are the ones the pinned
# commit records; `third_party/shine` is needed for MP3, which is what
# SillyTavern asks for.
{
  lib,
  pkgs,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  makeWrapper,
  vulkanSupport ? true,
  vulkan-headers,
  vulkan-loader,
  shaderc,
}: let
  # The application commit this package builds. Bumping it means re-deriving
  # `hash`, and re-checking the two submodule revisions below.
  rev = "2904b9ad126c07363e8a6c9afa08f73e3309075b";

  appSrc = fetchFromGitHub {
    owner = "HoppouAI";
    repo = "Breeze-TTS-2.cpp";
    inherit rev;
    hash = "sha256-Qt9fNWjHKHzYjlgzdhTpQeETu6LKhLU/8KNxRbSfTmM=";
  };

  ggmlSrc = fetchFromGitHub {
    owner = "ggml-org";
    repo = "ggml";
    rev = "36da57138425487184aa1da2eee2cde155909c6f";
    hash = "sha256-D9D/attiTe9MFT3sHbwTzPni3LxEVVGYsgKCb7V7qtE=";
  };

  shineSrc = fetchFromGitHub {
    owner = "toots";
    repo = "shine";
    rev = "ab5e3526b64af1a2eaa43aa6f441a7312e013519";
    hash = "sha256-rlKWVgIl/WVIzwwMuPyWaiwvbpZi5HvKXU3S6qLoN3I=";
  };
in
  stdenv.mkDerivation {
    pname = "breeze-tts-2${lib.optionalString (!vulkanSupport) "-cpu"}";
    version = "0.1.0";

    src = appSrc;

    # Fork-local until upstream reads per-voice generation defaults: a
    # `<name>.json` next to `<name>.breeze` supplies instruction/cfg/seed/
    # sampling, and an explicit request field still wins. The module writes the
    # sidecar; the browser UI and curl get the same defaults from the server.
    patches = [ ./voice-defaults.patch ];

    # The flake source has empty `third_party/*` directories, never the
    # submodules. Replace both with the pinned trees. This runs in the source
    # directory, before CMake reads it; `chmod` is needed because the unpacked
    # source is read-only.
    preConfigure = ''
      chmod -R u+w .
      rm -rf third_party/ggml third_party/shine
      ln -s ${ggmlSrc} third_party/ggml
      ln -s ${shineSrc} third_party/shine
    '';

    nativeBuildInputs =
      [
        cmake
        ninja
        pkg-config
      ]
      ++ lib.optionals vulkanSupport [
        makeWrapper
        shaderc
      ];

    buildInputs = lib.optionals vulkanSupport [
      vulkan-headers
      vulkan-loader
    ];

    cmakeFlags =
      [
        "-DCMAKE_BUILD_TYPE=Release"
        # Static ggml and no shared library: the server and CLI are the only
        # consumers here, and a static build cannot pick up a build-tree rpath.
        "-DBUILD_SHARED_LIBS=OFF"
        "-DGGML_OPENMP=OFF"
        "-DBREEZE_BUILD_SHARED=OFF"
        # Tests need model weights; they are not part of this package's contract.
        "-DBREEZE_BUILD_TESTS=OFF"
      ]
      ++ lib.optionals (!vulkanSupport) ["-DBREEZE_VULKAN=OFF"];

    # The project has no install() rules, so install from the build directory.
    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin"
      for exe in breeze-cli breeze-server breeze-convert breeze-quantize; do
        if [ -x "$exe" ]; then
          install -m755 "$exe" "$out/bin/$exe"
        fi
      done
      runHook postInstall
    '';

    # ggml dlopens the Vulkan loader rather than linking it, so the loader has to
    # be on the wrapper's LD_LIBRARY_PATH. No wrapper is needed for the CPU build.
    postFixup = lib.optionalString vulkanSupport ''
      for exe in breeze-cli breeze-server breeze-convert breeze-quantize; do
        if [ -x "$out/bin/$exe" ]; then
          wrapProgram "$out/bin/$exe" \
            --prefix LD_LIBRARY_PATH : "${vulkan-loader}/lib"
        fi
      done
    '';

    # The module reads this to refuse a Vulkan backend backed by a CPU-only
    # binary. A build flag is not otherwise observable from the outside.
    passthru.vulkanSupport = vulkanSupport;

    # The sidecar patch is fork-local, so it needs a behavioural test: the
    # synthetic .breeze files mean this compiles the server sources but never
    # loads a model. It covers the precedence the module promises (request >
    # voice sidecar > GenRequest default) and the 404 for an unknown voice.
    passthru.tests.voiceDefaults =
      let
        patchedSrc = pkgs.runCommand "breeze-tts-2-source" {
          nativeBuildInputs = [ pkgs.patch ];
        } ''
          cp -a ${appSrc} $out
          chmod -R u+w $out
          cd $out
          patch -p1 < ${./voice-defaults.patch}
        '';
      in
      pkgs.runCommand "breeze-tts-voice-defaults-test" {
        nativeBuildInputs = [ pkgs.gcc ];
      } ''
        cp -a ${patchedSrc} src
        cp ${./tests/sidecar.cpp} test.cpp
        g++ -std=c++17 -O1 -ffunction-sections -fdata-sections \
          -Isrc/apps/server -Isrc/include -Isrc/third_party \
          -I${ggmlSrc}/include \
          test.cpp src/apps/server/openai.cpp src/apps/server/voices.cpp src/src/voice.cpp \
          -Wl,--gc-sections -o test
        ./test "$PWD/voices"
        touch $out
      '';

    meta = {
      description = "Breeze-TTS-2.cpp: streaming GGUF text-to-speech server (${
        if vulkanSupport
        then "Vulkan"
        else "CPU"
      } backend)";
      homepage = "https://github.com/HoppouAI/Breeze-TTS-2.cpp";
      license = lib.licenses.asl20;
      # The source is Apache-2.0; the weights are NOT. They are covered by the
      # BreezeBlue Research and Non-Commercial License and are not fetched by
      # this derivation.
      platforms = lib.platforms.linux;
      mainProgram = "breeze-server";
    };
  }
