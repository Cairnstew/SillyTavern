#!/usr/bin/env bash
#
# nix-tests/live/test_tts_server.sh — live smoke test for the Breeze TTS backend.
#
# ── Why this is not a pytest ─────────────────────────────────────────────────
#
# `nix flake check` already covers everything that can be evaluated: the option
# tree, the rendered unit, the assertion set, and the VRAM guard run against a
# stubbed driver. What it cannot cover is whether the real binary loads a real
# GGUF and answers a real request — and that needs a GPU and 2.4+ GiB of weights,
# which is why this script is opt-in and separate.
#
# ── Running it ───────────────────────────────────────────────────────────────
#
#   BREEZE_TTS_MODEL=/var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf \
#     ./nix-tests/live/test_tts_server.sh
#
# Environment:
#   BREEZE_TTS_MODEL   path to a .gguf (required; the script does not download)
#   BREEZE_TTS_CPU=1   force the CPU backend (slow; skips the Vulkan assertion)
#   BREEZE_TTS_PORT    HTTP port (default 18137)
#
# Exits non-zero if the server fails to become healthy, returns a non-200, or
# produces no audio. A real-time factor below 1.0 is reported as a warning, not
# a failure: it is a property of the host, not a bug in the module.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SYSTEM="${ST_SYSTEM:-x86_64-linux}"
MODEL="${BREEZE_TTS_MODEL:-}"
PORT="${BREEZE_TTS_PORT:-18137}"
CPU="${BREEZE_TTS_CPU:-0}"

if [ -z "$MODEL" ]; then
  echo "BREEZE_TTS_MODEL is not set. Point it at a Breeze-TTS-2 GGUF, e.g." >&2
  echo "  BREEZE_TTS_MODEL=/var/lib/breeze-tts/models/breeze-tts-2-q4_k.gguf $0" >&2
  exit 2
fi

if [ ! -s "$MODEL" ]; then
  echo "model not found or empty: $MODEL" >&2
  exit 2
fi

PKG="$(nix build "$REPO#packages.$SYSTEM.breeze-tts" --no-link --print-out-paths)"
TMP="$(mktemp -d)"
PID=""

cleanup() {
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    wait "$PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

# The Vulkan ICDs NixOS exposes when hardware.graphics is enabled. Set only
# when the directory exists, so the CPU path is unaffected.
if [ "$CPU" != "1" ] && [ -d /run/opengl-driver/share/vulkan/icd.d ]; then
  export VK_ICD_FILENAMES="/run/opengl-driver/share/vulkan/icd.d:/run/opengl-driver-32/share/vulkan/icd.d"
fi

ARGS=(--host 127.0.0.1 --port "$PORT")
if [ "$CPU" = "1" ]; then
  ARGS+=(--cpu)
fi

echo "starting breeze-server on :$PORT ($([ "$CPU" = 1 ] && echo CPU || echo Vulkan))"
"$PKG/bin/breeze-server" "$MODEL" "${ARGS[@]}" >"$TMP/server.log" 2>&1 &
PID=$!

START=$(date +%s)
HEALTHY=0
for _ in $(seq 1 180); do
  if curl -fsS --max-time 2 "http://127.0.0.1:$PORT/health" >"$TMP/health.json" 2>/dev/null; then
    HEALTHY=1
    break
  fi
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "server exited during startup:" >&2
    cat "$TMP/server.log" >&2
    exit 1
  fi
  sleep 1
done

if [ "$HEALTHY" != "1" ]; then
  echo "server did not become healthy within 180s:" >&2
  cat "$TMP/server.log" >&2
  exit 1
fi

echo "healthy after $(( $(date +%s) - START ))s: $(cat "$TMP/health.json")"

if [ "$CPU" != "1" ]; then
  if grep -q "backend: Vulkan" "$TMP/server.log"; then
    echo "backend: $(grep -m1 'backend: Vulkan' "$TMP/server.log")"
  else
    echo "WARNING: the server did not report a Vulkan backend." >&2
    echo "It is running on the CPU. Check the driver and VK_ICD_FILENAMES." >&2
  fi
fi

CODE="$(
  curl -sS -o "$TMP/out.wav" -w '%{http_code} %{time_total}' \
    -X POST "http://127.0.0.1:$PORT/v1/audio/speech" \
    -H 'Content-Type: application/json' \
    -d '{"model":"tts-1","input":"This is the live speech test for the NixOS module. It is long enough to measure a real time factor.","instructions":"A warm, calm narrator with clear delivery.","response_format":"wav"}'
)"
read -r HTTP ELAPSED <<<"$CODE"

if [ "$HTTP" != "200" ]; then
  echo "speech request returned HTTP $HTTP:" >&2
  cat "$TMP/out.wav" >&2
  exit 1
fi

BYTES="$(wc -c <"$TMP/out.wav")"
if [ "$BYTES" -lt 1000 ]; then
  echo "speech request produced only $BYTES bytes" >&2
  exit 1
fi

AUDIO_SECONDS="$(python3 - "$TMP/out.wav" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read()
i = b.find(b'data')
size = struct.unpack('<I', b[i + 4:i + 8])[0]
if size > len(b) - (i + 8):
    size = len(b) - (i + 8)
print(f"{size / 2 / 24000:.2f}")
PY
)"

RTF="$(python3 -c "print(f'{$AUDIO_SECONDS / $ELAPSED:.2f}')")"
echo "generated ${AUDIO_SECONDS}s of audio in ${ELAPSED}s -> ${RTF}x realtime"

if python3 -c "import sys; sys.exit(0 if $RTF < 1.0 else 1)"; then
  echo "WARNING: slower than realtime on this host; streamed playback will stutter." >&2
fi

grep -E "frames in|first audio" "$TMP/server.log" | tail -2 || true
echo "PASS tts-live (health, OpenAI-compatible speech, non-empty audio)"
