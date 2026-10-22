# lib/tts-models.nix
#
# The shipped Breeze-TTS-2.cpp GGUF catalogue, in one pure place so the module,
# the tests and the docs all describe the same files.
#
# ── Where the numbers come from ───────────────────────────────────────────────
#
# `sizeMiB` is the byte size reported by the Hugging Face tree API, rounded up
# to the next MiB. `sha256` is the LFS object id from that same API, which is
# the hex digest of the file content, so `sha256sum -c` verifies a download.
#
# `vramMiB` is the project's own published approximation, "about 1 GB above the
# file size", rounded UP to a whole MiB. It is an estimate, not a measurement:
# the guard uses it to refuse a start that cannot fit, and the runtime check
# still reads the driver's real free-VRAM figure. The two are deliberately
# separate — a wrong estimate must not be the only thing standing between a
# server and an OOM.
#
# `ramMiB` is the systemd MemoryMax default: the file size plus 2 GiB of
# headroom for the tokenizer, request buffers and the vocoder's working set.
# Only the *mapped* weights are counted; the GPU holds the rest.
#
# The `-dd` variants quantise the depth decoder as well. They are smaller and
# faster on some cards, but upstream documents audible drift past roughly 45 s
# of continuous narration, so q8_0 or q4_k is the safe choice.
{
  f16 = {
    file = "breeze-tts-2-f16.gguf";
    sha256 = "db740cd464d75f2635a891586f083c5b466fd63542bebd957fe7890324b04c35";
    sizeMiB = 5989;
    vramMiB = 7168;
    ramMiB = 8192;
    note = "Reference quality. Needs about 7 GiB of VRAM; never fits beside a large LLM on a 12 GiB card.";
  };

  q8_0 = {
    file = "breeze-tts-2-q8_0.gguf";
    sha256 = "a02bcc4b69b0601032727f8040c4942149b1b73aa0f69022fe5aaa6a8f0ef879";
    sizeMiB = 3404;
    vramMiB = 4096;
    ramMiB = 5632;
    note = "Upstream's recommendation and the best quality that reliably fits beside a Q4 8B on 12 GiB, if the LLM is kept under roughly 7 GiB.";
  };

  q6_k = {
    file = "breeze-tts-2-q6_k.gguf";
    sha256 = "0eb51de6cbccd54b1c408198797254ac46b3cbd55ca1174c630eaac6d01064d3";
    sizeMiB = 2928;
    vramMiB = 3584;
    ramMiB = 5120;
    note = "Middle ground between q8_0 and q4_k.";
  };

  q4_k = {
    file = "breeze-tts-2-q4_k.gguf";
    sha256 = "483418fbbb438f5f1c08dbe2b017e42db0f1d126765cd3f772d8622a30a4915c";
    sizeMiB = 2422;
    vramMiB = 3072;
    ramMiB = 4608;
    note = "Upstream's 'smallest safe choice'. The default for a 12 GiB card shared with an 8B LLM.";
  };

  q8_0-dd4 = {
    file = "breeze-tts-2-q8_0-dd4.gguf";
    sha256 = "5248f348388cb7fd904a8bde3e65383a0fbc562d2fe48d7c375cf17372d3751b";
    sizeMiB = 3244;
    vramMiB = 4352;
    ramMiB = 5632;
    note = "Experimental: Q8_0 backbone with a Q4_K depth decoder. Faster on some cards, drifts on long passages.";
  };

  q8_0-dd2 = {
    file = "breeze-tts-2-q8_0-dd2.gguf";
    sha256 = "c43155fdd783e459f84c78b88f6cd91e833cf8b54649f289de7825139ee2d1c9";
    sizeMiB = 3169;
    vramMiB = 4224;
    ramMiB = 5632;
    note = "Experimental: Q8_0 backbone with a Q2_K depth decoder. More drift than -dd4.";
  };

  q4_k-dd2 = {
    file = "breeze-tts-2-q4_k-dd2.gguf";
    sha256 = "6d675f8c1ce43bdd368489e9c9f52a725e9ede23e3bbf338ec5c9c31d8169cf0";
    sizeMiB = 2347;
    vramMiB = 3456;
    ramMiB = 4608;
    note = "Experimental: smallest variant. Fine for short lines, not for narration.";
  };
}
