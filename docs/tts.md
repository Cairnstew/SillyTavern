# Local speech: the Breeze TTS 2 backend

`services.breeze-tts-nixos` runs [Breeze-TTS-2.cpp] — a C++/GGUF reimplementation
of [BreezeBlue/Breeze-TTS-2] — as a systemd service, and exposes an
OpenAI-compatible `/v1/audio/speech` endpoint that SillyTavern can use as a TTS
provider. It is a **separate module** from `services.sillytavern-nixos` and
`services.llama-cpp-nixos`: three services, three lifetimes, none forcing another
on.

```nix
imports = [ inputs.sillytavern.nixosModules.breeze-tts ];

services.breeze-tts-nixos = {
  enable = true;
  model = "q4_k";              # a catalogue entry; see lib/tts-models.nix
  gpu.totalVramMiB = 12288;    # the card, for the static budget check
  gpu.reserveForOtherMiB = 7000; # what the LLM is allowed to hold
};
```

> **Licence.** The *source code* is Apache-2.0. The **weights are not**: they are
> governed by the BreezeBlue Research and Non-Commercial License. Personal use is
> covered; hosting the model as a service for others is not. The module emits a
> warning on every evaluation, and the weights are never fetched by a build.

[Breeze-TTS-2.cpp]: https://github.com/HoppouAI/Breeze-TTS-2.cpp
[BreezeBlue/Breeze-TTS-2]: https://huggingface.co/BreezeBlue/Breeze-TTS-2

---

## 1. Is it viable on a 12 GiB card shared with an 8B LLM?

Yes, with the Q4_K quantisation, and this repository measured it rather than
trusting the model card. The test host was an RTX 3060 12 GiB with an 8B Q4 LLM
already resident (7.1 GiB used, 4.8 GiB free).

| Quantity | Measured |
|---|---|
| Model file (Q4_K) | 2.4 GiB, sha256 verified against the Hub LFS oid |
| Extra VRAM while serving | **≈ 3.0 GiB** (7.15 → 10.2 GiB used) |
| Startup to `/health` | 11 s cold (includes the pipeline warm-up) |
| First audio | **≈ 190 ms** after warm-up |
| Real-time factor | **≈ 2.0×** (7.2 s of audio in 3.6 s) |
| Backend chosen | `Vulkan1` (RTX 3060), not `Vulkan0` (the Vega iGPU) |

That leaves roughly 1.7 GiB free on the card at rest. The Q8_0 variant needs
about 1 GiB more and would be the right choice only if the LLM's own footprint is
kept smaller.

### The quantisation ladder

From `lib/tts-models.nix` (upstream's published approximations; the `sizeMiB` is
the real file size):

| `model` | File | Approx. VRAM | System RAM cap | Notes |
|---|---|---|---|---|
| `f16` | 5.9 GiB | ~7 GiB | 8 GiB | Reference quality. Will not fit beside a large LLM on 12 GiB. |
| `q8_0` | 3.3 GiB | ~4 GiB | 5.5 GiB | Upstream's recommendation. Fits if the LLM stays under ~7 GiB. |
| `q6_k` | 2.9 GiB | ~3.5 GiB | 5 GiB | Middle ground. |
| `q4_k` | 2.4 GiB | ~3 GiB | 4.5 GiB | Upstream's "smallest safe choice". **The default to reach for here.** |
| `q8_0-dd4` | 3.2 GiB | ~4.3 GiB | 5.5 GiB | Experimental: quantised depth decoder. Drifts past ~45 s of narration. |
| `q8_0-dd2` | 3.1 GiB | ~4.1 GiB | 5.5 GiB | Experimental, more drift than `-dd4`. |
| `q4_k-dd2` | 2.3 GiB | ~3.4 GiB | 4.5 GiB | Experimental, smallest. Short lines only. |

The `-dd` variants are faster on some cards because the depth decoder runs 15
sequential steps per audio frame. Upstream documents that the damage grows with
length, so they are not for narration.

---

## 2. The overload guards

The upstream server has no authentication, no rate limiting and no VRAM ceiling.
Vulkan has no per-process VRAM limit and neither does systemd — `MemoryMax` caps
RAM, not device memory. So this module makes the footprint a *contract* and
checks it twice.

### 2a. Static budget, at evaluation time

```nix
gpu.totalVramMiB = 12288;      # the card
gpu.reserveForOtherMiB = 7000; # what the other consumer (the LLM) will hold
```

`nixos-rebuild` fails with the arithmetic if

```
requiredVramMiB + headroomMiB + reserveForOtherMiB > totalVramMiB
```

`requiredVramMiB` defaults from the catalogue for a `model`, and is **required
explicitly** for a custom GGUF — the guard will not guess a footprint for a file
it has never seen.

### 2b. Runtime probe, at `ExecStartPre`

A generated script reads the driver's real free VRAM for `gpu.deviceIndex`
(`nvidia-smi` on NVIDIA, `mem_info_vram_*` on AMD) and refuses to start when

```
free < requiredVramMiB + headroomMiB
```

It deliberately does **not** add `reserveForOtherMiB`. If the LLM is already
resident, its footprint has already reduced the free figure; adding it again
would refuse a start that plainly fits. The reserve exists for the case where the
LLM has not started yet, and the static check is what guarantees it will still
fit afterwards.

`gpu.requireGpu = true` (the default) also means *no readable GPU is a refusal*,
not a silent CPU fallback — a fallback that would otherwise pin every core.

The check is exercised in `nix flake check` by `breezeTtsVramGuard`, which runs
the generated script against a stubbed `nvidia-smi` and requires it to accept a
start that fits and refuse one that does not.

### 2c. systemd caps

| Option | Default | What it stops |
|---|---|---|
| `hardware.memoryMax` | file size + 2 GiB (catalogue) | The process growing into the machine's RAM. |
| `hardware.memorySwapMax` | `0` | A swapped-out vocoder turning a slow request into a machine-wide stall. |
| `hardware.cpuQuota` | `400%` | A CPU fallback pinning every core. |
| `hardware.nice` | `5` | TTS competing with interactive work. |
| `tasksMax` (unit) | `64` | Thread explosion. |
| `StartLimitBurst` (unit) | 3 per 300 s | A crash loop restarting into a GPU that is still occupied. |

### 2d. Bounded requests

- The server itself accepts **one generation at a time**; a second concurrent
  request gets `409` rather than a queue, so there is no internal fan-out.
- `splitChars` (default 300) bounds the per-piece compute of the otherwise
  unbounded `text` field.
- `chunkMax` (default 40) bounds the streaming buffer; higher values do not buy
  throughput but demand a deeper client queue.

There is **no** total-request time limit. A client can send an enormous text and
keep the server busy for as long as the text implies. Put a reverse proxy in
front if that matters, and keep `host` on loopback.

---

## 3. Wiring SillyTavern to it — automatic

**You do not have to write the TTS settings.** Enabling the backend is enough:
the SillyTavern module notices an enabled `services.breeze-tts-nixos` in the same
system and points the TTS extension at it.

```nix
imports = [
  inputs.sillytavern.nixosModules.sillytavern
  inputs.sillytavern.nixosModules.breeze-tts
];

services.breeze-tts-nixos.enable = true;
services.breeze-tts-nixos.model = "q4_k";
```

That writes, into every account's `settings.json`:

```json
"extension_settings": {
  "tts": {
    "currentProvider": "OpenAI Compatible",
    "enabled": false,
    "OpenAI Compatible": {
      "provider_endpoint": "http://127.0.0.1:<breeze port>/v1/audio/speech",
      "model": "tts-1",
      "available_voices": [],
      "voiceMap": {},
      "speed": 1
    }
  }
}
```

The read is one-way and optional: the SillyTavern module never sets a Breeze
option, and the Breeze module never reads the SillyTavern module. A system with
only `nixosModules.sillytavern` renders exactly the `settings.json` it did
before. `ttsAutoWiring` in `lib/tests.nix` pins all four cases (enabled, absent,
overridden, disabled).

### Knobs, when the defaults are not what you want

| Option | Default | Effect |
|---|---|---|
| `services.sillytavern-nixos.tts.autoConfigure` | `true` | `false` writes nothing; manage `extension_settings.tts` yourself. |
| `…tts.enable` | `false` | `true` makes the UI speak replies on load (`extension_settings.tts.enabled`). |
| `…tts.endpoint` | `null` | Full `/v1/audio/speech` URL. `null` derives it from the Breeze port; set it for a server on another host. |
| `…tts.voices` | `[ ]` | The voice ids the UI offers. |
| `…tts.model` | `"tts-1"` | Required by SillyTavern, ignored by the server. |
| `…tts.autoGeneration` | `null` | `extension_settings.tts.auto_generation`. |

An explicit `settingsExtra.extensionSettings.tts` (or `settings.common`, or a
per-account value) always **overrides** the generated defaults leaf by leaf, so
the manual block below still works when you need it:

```nix
services.sillytavern-nixos.settingsExtra.extensionSettings.tts."OpenAI Compatible".available_voices = [
  "narrator"
  "harbour"
];
```

### Notes

- **The endpoint is reached server-side.** Upstream's OpenAI-Compatible provider
  does not `fetch()` the endpoint from the browser; it POSTs to SillyTavern's own
  `/api/openai/custom/generate-voice`, which proxies from the server
  (`src/endpoints/openai.js`). So `127.0.0.1` is correct even when the browser is
  remote, and **CORS is irrelevant** for this provider.
- The API key field is ignored by the server; any value works.
- `available_voices` is empty by default. An empty dropdown still works for
  reference-free **voice design** (the request sends no voice); to pick a voice,
  register one on the server with `POST /v1/voices` and list its id in
  `tts.voices`.
- `speed` does nothing — the model has no speed control.
- The server returns MP3 for SillyTavern's requests (the package builds the
  `shine` encoder). If MP3 is unavailable it sends WAV.
- `tts.enable = true` with no backend enabled and no `tts.endpoint` emits a
  warning: there would be nothing to point at.

---

## 4. Getting the weights

Nothing is downloaded at build time, and nothing is downloaded at start unless
you ask. Three ways:

**Operator-managed (default).** Put the file where the module expects it:

```bash
curl -fL --create-dirs \
  -o /var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf \
  https://huggingface.co/HoppouAI/Breeze-TTS-2.cpp/resolve/main/breeze-tts-2-q4_k.gguf
```

The module checks the file exists and fails with the exact command if it does
not.

**Verified at start.**

```nix
services.breeze-tts-nixos.downloadModel = true;
```

The unit fetches the file into `modelDirectory` and verifies the pinned sha256 on
every start; an already-correct file makes it a no-op, and a mismatch is
discarded and re-fetched. This is the only mode that touches the network at
activation, and it is off by default.

**Pinned in the store.** `weights.url` + `weights.hash` fetches at build time
with `pkgs.fetchurl`. It adds 2.4–6 GiB to the closure, so it is the right choice
only when reproducibility outweighs store size.

---

## 5. Caveats worth knowing

- **English and Mandarin only.** The vendor claims more languages; the model card
  documents two.
- **No authentication and no rate limiting**, on either the HTTP or WebSocket
  port. Keep `host` on loopback, or put a proxy in front. The module warns when
  you do not.
- **The runtime is young** (v0.1.0 prebuilt release). Expect rough edges, and
  pin the commit (`pkgs/breeze-tts-2/default.nix`) when bumping.
- **Device selection is ggml's.** On a machine with both an iGPU and a discrete
  card, ggml prefers the discrete one (observed: it picked the RTX 3060 over the
  Vega iGPU). The guard reads the NVIDIA card via `nvidia-smi` or the first AMD
  card with a VRAM node; if the log's `backend:` line ever names the wrong
  device, the guard and the model disagree.
- **Warm-up matters.** The default warm-up costs ~11 s of startup cold and takes
  first audio from ~17 s to ~190 ms. `noWarmup = true` moves that cost into the
  first request instead.
- **Cloning quality is average.** Upstream's blind-test ranking comes from its
  stock/designed voices; controlled voice-cloning scores are a three-way tie with
  Voxtral TTS and Fish S2 Pro. Voxtral is the better pure cloner but needs 16 GB.

### Alternatives considered

| Model | Why not chosen here |
|---|---|
| **Voxtral TTS** | Better pure cloner, but ~16 GB — does not fit beside the LLM. |
| **VoxCPM2** | Permissive and multilingual, but ~8 GB at full precision; needs quantisation or CPU. |
| **Chatterbox (MIT)** | The safe, comfortable fit, but lower quality. A reasonable fallback if the licence or VRAM is a blocker. |

---

## 6. Testing it

```bash
just tts-test        # the six evaluation checks (no GPU needed)
just tts-build       # build the Vulkan package
BREEZE_TTS_MODEL=/var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf just tts-live
```

`just tts-live` runs `nix-tests/live/test_tts_server.sh`, which starts the real
server against a real model, asserts `/health`, generates a short clip over the
OpenAI-compatible endpoint, and reports the measured real-time factor. It is
opt-in because it needs a GPU and the weights; it is not part of
`nix flake check`.
