#!/usr/bin/env python3
"""Generate a SillyTavern character card with help from a local model.

A character card is the one JSON document SillyTavern actually reads for a
character: the TavernCard v2 shape (`spec: chara_card_v2`, `spec_version:
2.0`, `data` with `name`, `description`, `personality`, `scenario`,
`first_mes`, `mes_example`, `alternate_greetings`, `tags`, and friends —
see `src/validator/TavernCardValidator.js`). Hand-writing one that is both
valid and good is fiddly: miss a required key and the import is refused, and a
thin `description` gives the model nothing to roleplay with.

This script walks the operator through a FIXED questionnaire — the same
questions in the same order every run, so two cards built from the same notes
have the same structure — and then asks a chat-completion endpoint to draft
the long-form fields from those answers. The endpoint is any OpenAI-compatible
one: Ollama (`http://127.0.0.1:11434/v1`), the llama.cpp server this flake
ships (`http://127.0.0.1:9931/v1`), vLLM, LM Studio, or anything else behind
`/chat/completions`.

It is deliberately narrow:

  * STDLIB ONLY. No `requests`, no `Pillow`: the wrapper this ships in puts
    exactly `python3` on PATH, so `urllib` does the HTTP and `struct`/`zlib`
    do the PNG embedding. A third-party import here is a runtime failure on
    every machine that installs the tool.
  * DETERMINISTIC STRUCTURE. The questionnaire order, the JSON schema sent to
    the model, and the validation afterwards are all fixed. The model supplies
    prose; it never supplies structure. Anything that is not valid v2 is
    rejected and re-asked with the reason quoted (up to `--max-attempts`),
    then reported — never written half-fixed.
  * `--dry-run` writes a cleanly-structured card from the answers alone, with
    no network at all. The card is thinner (template prose instead of drafted
    prose) but still valid, which is what makes this script testable without
    a model and usable on a machine with no endpoint.
  * NOTHING is overwritten unless asked. `--out` refuses to clobber an
    existing file without `--force`, and writing into a data root goes to
    `<dataRoot>/<handle>/characters/`, the directory the server actually
    reads characters from.

Typical use::

    st-mkchar --endpoint http://127.0.0.1:11434/v1 --model llama3.1
    st-mkchar --non-interactive --concept "a retired lighthouse keeper ..." \\
        --name "Mara Voss" --out ./Mara.json
    st-mkchar --dry-run --non-interactive --concept "..." --name Mara --out ./Mara.json
    st-mkchar --out ./Mara.json --png ./mara-avatar.png
    st-mkchar --to-data-root /var/lib/sillytavern --handle default-user --out ./Mara.json

When the NixOS module enables this (`services.sillytavern-nixos.charGen`),
the endpoint and model default to the instance's own backends, so the first
form becomes just `st-mkchar`.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import json
import os
import re
import struct
import sys
import urllib.error
import urllib.request
import zlib
from typing import Any

CARD_SPEC = "chara_card_v2"
CARD_SPEC_VERSION = "2.0"

# Every key `TavernCardValidator.js` requires under `data` for v2. This list
# is the contract: `build_card` always emits exactly these keys, and
# `validate_card` refuses anything missing one. An upstream rename fails the
# unit tests (`nix-tests/test_mkchar.py`) rather than producing a card the
# import dialog rejects.
REQUIRED_DATA_FIELDS = [
    "name",
    "description",
    "personality",
    "scenario",
    "first_mes",
    "mes_example",
    "creator_notes",
    "system_prompt",
    "post_history_instructions",
    "alternate_greetings",
    "tags",
    "creator",
    "character_version",
    "extensions",
]

DEFAULT_ENDPOINT = "http://127.0.0.1:11434/v1"
DEFAULT_MODEL = "llama3.1"
DEFAULT_CREATOR = "st-mkchar"
DEFAULT_CHARACTER_VERSION = "1.0.0"
REQUEST_TIMEOUT_SECONDS = 300


def _log(msg: str) -> None:
    print(f"st-mkchar: {msg}", file=sys.stderr, flush=True)


class CardError(Exception):
    """Anything that must stop the run before a card is written."""


# ── the questionnaire ─────────────────────────────────────────────────────────
#
# Fixed order, fixed keys. Each entry is one question the operator answers;
# the answers become the `notes` the prompt builder renders verbatim into the
# system prompt. Adding a question means appending here AND handling the key in
# `build_prompt` — a key nobody reads is a question nobody should have been
# asked.
QUESTIONS: list[dict[str, Any]] = [
    {
        "key": "concept",
        "prompt": "One-paragraph concept (who is this character, in one breath?)",
        "required": True,
        "help": "e.g. 'a retired lighthouse keeper who maps storms from memory and talks to gulls by name'",
    },
    {
        "key": "name",
        "prompt": "Character name",
        "required": True,
        "help": "The display name and file name. Letters, digits, spaces, - and _ only.",
    },
    {
        "key": "personality_notes",
        "prompt": "Personality in a few adjectives or a sentence",
        "required": False,
        "help": "e.g. 'dry-humoured, patient, blunt about danger, soft with animals'",
    },
    {
        "key": "scenario_notes",
        "prompt": "Where does a first conversation happen? (one line)",
        "required": False,
        "help": "e.g. 'the {{user}} shelters in the lighthouse during a gale'",
    },
    {
        "key": "speech_notes",
        "prompt": "How do they talk? (one line, optional)",
        "required": False,
        "help": "e.g. 'short sentences, sea metaphors, never uses contractions when afraid'",
    },
    {
        "key": "greeting_seed",
        "prompt": "First-message seed — what should the opening beat be? (one line, optional)",
        "required": False,
        "help": "e.g. 'Mara finds the user dripping in her doorway and offers a blanket before a name'",
    },
    {
        "key": "alt_greetings_count",
        "prompt": "How many alternate greetings? (0-5)",
        "required": False,
        "default": "2",
        "help": "Alternate first messages the user can swipe between. 2 is a good default.",
    },
    {
        "key": "tags",
        "prompt": "Tags, comma-separated (optional)",
        "required": False,
        "help": "e.g. 'slow-burn, seaside, gruff-hearted'. Used for search, not for the model.",
    },
    {
        "key": "creator",
        "prompt": "Creator name for the card metadata",
        "required": False,
        "default": DEFAULT_CREATOR,
        "help": "Stamped into data.creator. Cosmetic.",
    },
    {
        "key": "nsfw_ok",
        "prompt": "May the card include mature/erotic content? (yes/no)",
        "required": False,
        "default": "no",
        "help": "Recorded so the model does not smuggle it in unasked. Defaults to no.",
    },
]


def safe_filename(name: str) -> str:
    """Turn a character name into a file stem the server will list cleanly."""
    stem = re.sub(r"[^A-Za-z0-9 _-]+", "", name).strip()
    stem = re.sub(r"\s+", " ", stem)
    if not stem:
        raise CardError(f"name {name!r} has nothing file-safe left in it")
    return stem


def ask_interactive(pre: dict[str, str]) -> dict[str, str]:
    """Ask every question not already answered, in the fixed order."""
    answers = dict(pre)
    _log("answer each question; empty keeps the default shown in [brackets].")
    for q in QUESTIONS:
        if answers.get(q["key"]):
            continue
        default = answers.get(q["key"]) or q.get("default") or ""
        suffix = f" [{default}]" if default else ""
        try:
            raw = input(f"{q['prompt']}{suffix}: ").strip()
        except EOFError:
            raise CardError("input closed; use --non-interactive with flags instead")
        value = raw or default
        if q.get("required") and not value:
            raise CardError(f"{q['key']} is required and no default exists")
        answers[q["key"]] = value
        if q.get("help") and not raw:
            pass  # help is printed once below, not per question
    return answers


def parse_tags(raw: str) -> list[str]:
    return [t.strip() for t in (raw or "").split(",") if t.strip()]


def normalise_answers(answers: dict[str, str]) -> dict[str, Any]:
    """Validate the raw answers and coerce counts/lists to their real types."""
    concept = (answers.get("concept") or "").strip()
    name = (answers.get("name") or "").strip()
    if not concept:
        raise CardError("a concept is required (one paragraph, one breath)")
    if not name:
        raise CardError("a name is required")
    if not re.fullmatch(r"[A-Za-z0-9 _-]+", name):
        raise CardError(
            f"name {name!r} must be letters, digits, spaces, - and _ only"
        )
    try:
        alt_count = int((answers.get("alt_greetings_count") or "2").strip() or "2")
    except ValueError:
        raise CardError("alt_greetings_count must be a number 0-5")
    if not 0 <= alt_count <= 5:
        raise CardError("alt_greetings_count must be 0-5")
    nsfw_raw = (answers.get("nsfw_ok") or "no").strip().lower()
    nsfw_ok = nsfw_raw in ("yes", "y", "true", "1")
    return {
        "concept": concept,
        "name": name,
        "personality_notes": (answers.get("personality_notes") or "").strip(),
        "scenario_notes": (answers.get("scenario_notes") or "").strip(),
        "speech_notes": (answers.get("speech_notes") or "").strip(),
        "greeting_seed": (answers.get("greeting_seed") or "").strip(),
        "alt_greetings_count": alt_count,
        "tags": parse_tags(answers.get("tags") or ""),
        "creator": (answers.get("creator") or DEFAULT_CREATOR).strip() or DEFAULT_CREATOR,
        "nsfw_ok": nsfw_ok,
    }


# ── the model prompt ──────────────────────────────────────────────────────────
#
# One call, one JSON object, fixed schema. The notes are rendered VERBATIM —
# the model gets the operator's words, not a paraphrase — and the schema is
# stated as literal keys so a model that "helpfully" renames one fails
# validation instead of producing a card that looks right and imports wrong.

SCHEMA_KEYS_DOC = """{
  "description": "2-4 paragraphs, physical presence + backstory hooks, {{char}} / {{user}} macros allowed",
  "personality": "one paragraph, traits as behaviour not adjectives-alone",
  "scenario": "where the conversation starts and why {{user}} is there",
  "first_mes": "the opening message, in character, 80-200 words",
  "mes_example": "two short <START> delimited example exchanges, in character",
  "alternate_greetings": ["N alternate opening messages, each a different situation"],
  "system_prompt": "one paragraph of roleplay instructions, or empty string",
  "post_history_instructions": "one short style nudge, or empty string",
  "creator_notes": "one line on intended use, or empty string"
}"""


def build_prompt(notes: dict[str, Any]) -> list[dict[str, str]]:
    lines = [
        "You are writing a roleplay character card for SillyTavern (TavernCard v2).",
        "Draft the long-form fields from the operator's notes below.",
        f"Concept: {notes['concept']}",
        f"Name: {notes['name']}",
    ]
    if notes["personality_notes"]:
        lines.append(f"Personality notes: {notes['personality_notes']}")
    if notes["scenario_notes"]:
        lines.append(f"Scenario notes: {notes['scenario_notes']}")
    if notes["speech_notes"]:
        lines.append(f"Speech notes: {notes['speech_notes']}")
    if notes["greeting_seed"]:
        lines.append(f"First-message seed: {notes['greeting_seed']}")
    lines.append(f"Tags (for search only, do not weave in): {', '.join(notes['tags']) or 'none'}")
    lines.append(
        "Mature content: "
        + ("allowed, write frankly" if notes["nsfw_ok"] else "not wanted, keep it clean")
    )
    lines.extend(
        [
            f"Write EXACTLY {notes['alt_greetings_count']} alternate greetings.",
            "Reply with ONE JSON object and nothing else — no fences, no commentary —",
            "with exactly these keys:",
            SCHEMA_KEYS_DOC,
        ]
    )
    return [
        {
            "role": "system",
            "content": (
                "You write roleplay character cards as strict JSON. "
                "You always reply with exactly one JSON object, no markdown fences."
            ),
        },
        {"role": "user", "content": "\n".join(lines)},
    ]


# ── chat-completions client (urllib; stdlib only) ─────────────────────────────


def normalise_endpoint(endpoint: str) -> str:
    base = (endpoint or "").strip().rstrip("/")
    if not base:
        raise CardError("endpoint is empty")
    if base.endswith("/chat/completions"):
        return base
    return base + "/chat/completions"


def post_chat_completions(
    endpoint: str,
    model: str,
    messages: list[dict[str, str]],
    api_key: str | None,
    temperature: float,
    timeout: int = REQUEST_TIMEOUT_SECONDS,
) -> str:
    url = normalise_endpoint(endpoint)
    payload: dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "stream": False,
    }
    # Ask for JSON mode where the server speaks it; Ollama's /v1 and vLLM do,
    # llama.cpp's server ignores unknown fields harmlessly. A 400 below falls
    # back to the same body without it.
    bodies = [
        {**payload, "response_format": {"type": "json_object"}},
        payload,
    ]
    headers = {"Content-Type": "application/json"}
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    last_error: Exception | None = None
    for body in bodies:
        req = urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8"),
            headers=headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                doc = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", "replace")[:500]
            last_error = CardError(f"endpoint returned HTTP {exc.code}: {detail}")
            if exc.code == 400 and "response_format" in body:
                continue  # retry without JSON mode
            raise last_error from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise CardError(f"cannot reach {url}: {exc}") from exc
        try:
            return str(doc["choices"][0]["message"]["content"])
        except (KeyError, IndexError, TypeError) as exc:
            raise CardError(f"unexpected chat-completions shape: {exc}") from exc
    raise last_error or CardError(f"no usable response from {url}")


def coerce_json_object(text: str) -> dict[str, Any]:
    """Parse the model's reply, tolerating fences and stray prose around it."""
    raw = text.strip()
    fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", raw, re.DOTALL)
    if fenced:
        raw = fenced.group(1)
    else:
        start, end = raw.find("{"), raw.rfind("}")
        if start != -1 and end > start:
            raw = raw[start : end + 1]
    try:
        doc = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise CardError(f"model did not return JSON ({exc}); first 200 chars: {raw[:200]!r}")
    if not isinstance(doc, dict):
        raise CardError("model returned a JSON array/scalar, need an object")
    return doc


# ── card assembly + validation ────────────────────────────────────────────────


def draft_from_template(notes: dict[str, Any]) -> dict[str, Any]:
    """Build the long-form fields WITHOUT a model (`--dry-run`).

    Template prose, not drafted prose — every field is present, correctly
    typed, and traceable to an answer, which is what "cleanly structured"
    needs when there is no endpoint to call.
    """
    name = notes["name"]
    personality = notes["personality_notes"] or f"{name} is defined by the concept below."
    scenario = notes["scenario_notes"] or f"{name} meets {{{{user}}}} as the concept describes."
    speech = f" Speech: {notes['speech_notes']}" if notes["speech_notes"] else ""
    seed = notes["greeting_seed"] or f"{name} greets {{{{user}}}}."
    alts = [
        f"Alternate greeting {i + 1}: {name} meets {{{{user}}}} under different circumstances. ({seed})"
        for i in range(notes["alt_greetings_count"])
    ]
    return {
        "description": f"{notes['concept']}{speech}",
        "personality": personality,
        "scenario": scenario,
        "first_mes": f"*{seed}*",
        "mes_example": f"<START>\n{{{{user}}}}: Hello, {name}.\n{{{{char}}}}: {seed}",
        "alternate_greetings": alts,
        "system_prompt": "",
        "post_history_instructions": "",
        "creator_notes": f"Drafted offline from the operator's concept for {name}.",
    }


def build_card(notes: dict[str, Any], drafted: dict[str, Any]) -> dict[str, Any]:
    missing = [k for k in ("description", "personality", "scenario", "first_mes") if not drafted.get(k)]
    if missing:
        raise CardError(f"draft is missing required prose: {', '.join(missing)}")
    alt_n = notes["alt_greetings_count"]
    alts = drafted.get("alternate_greetings") or []
    if not isinstance(alts, list):
        raise CardError("draft alternate_greetings is not a list")
    if len(alts) != alt_n:
        raise CardError(
            f"draft has {len(alts)} alternate greetings, asked for {alt_n}"
        )
    return {
        "spec": CARD_SPEC,
        "spec_version": CARD_SPEC_VERSION,
        "data": {
            "name": notes["name"],
            "description": str(drafted["description"]),
            "personality": str(drafted["personality"]),
            "scenario": str(drafted["scenario"]),
            "first_mes": str(drafted["first_mes"]),
            "mes_example": str(drafted.get("mes_example") or ""),
            "creator_notes": str(drafted.get("creator_notes") or ""),
            "system_prompt": str(drafted.get("system_prompt") or ""),
            "post_history_instructions": str(drafted.get("post_history_instructions") or ""),
            "alternate_greetings": [str(a) for a in alts],
            "tags": list(notes["tags"]),
            "creator": notes["creator"],
            "character_version": DEFAULT_CHARACTER_VERSION,
            "extensions": {},
        },
    }


def validate_card(card: dict[str, Any]) -> None:
    """Mirror `TavernCardValidator.js` v2: every required key, right types."""
    if card.get("spec") != CARD_SPEC:
        raise CardError(f"card spec is {card.get('spec')!r}, need {CARD_SPEC!r}")
    if card.get("spec_version") != CARD_SPEC_VERSION:
        raise CardError(f"card spec_version is {card.get('spec_version')!r}")
    data = card.get("data")
    if not isinstance(data, dict):
        raise CardError("card has no data object")
    absent = [k for k in REQUIRED_DATA_FIELDS if k not in data]
    if absent:
        raise CardError(f"card data is missing: {', '.join(absent)}")
    if not isinstance(data["alternate_greetings"], list):
        raise CardError("data.alternate_greetings must be a list")
    if not isinstance(data["tags"], list):
        raise CardError("data.tags must be a list")
    if not isinstance(data["extensions"], dict):
        raise CardError("data.extensions must be an object")
    for key in ("name", "description", "personality", "scenario", "first_mes"):
        if not str(data[key]).strip():
            raise CardError(f"data.{key} must not be empty")


# ── PNG embedding (tEXt "chara"; stdlib only) ─────────────────────────────────
#
# A SillyTavern PNG card is a plain PNG whose `tEXt` chunk with keyword
# `chara` holds the base64 card JSON. `Pillow` would do this in one call, but
# it is not on PATH in the wrapper — so this re-implements the 30 lines that
# matter: verify the signature, splice one chunk before IEND, recompute CRCs.

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    return (
        struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", binascii.crc32(chunk_type + data) & 0xFFFFFFFF)
    )


def embed_card_in_png(card: dict[str, Any], avatar: bytes) -> bytes:
    if not avatar.startswith(PNG_SIGNATURE):
        raise CardError("avatar is not a PNG (bad signature)")
    payload = base64.b64encode(
        json.dumps(card, ensure_ascii=False).encode("utf-8")
    )
    text_data = b"chara\x00" + payload
    offset, out = len(PNG_SIGNATURE), bytearray(PNG_SIGNATURE)
    end = len(avatar)
    inserted = False
    while offset + 8 <= end:
        (length,) = struct.unpack(">I", avatar[offset : offset + 4])
        ctype = avatar[offset + 4 : offset + 8]
        total = 4 + 4 + length + 4
        chunk = avatar[offset : offset + total]
        if len(chunk) != total:
            raise CardError("avatar PNG is truncated")
        if ctype == b"IEND" and not inserted:
            out += png_chunk(b"tEXt", text_data)
            inserted = True
        out += chunk
        offset += total
    if not inserted:
        raise CardError("avatar PNG has no IEND chunk")
    return bytes(out)


def extract_card_from_png(avatar: bytes) -> dict[str, Any]:
    """Read back the embedded card — used by the tests and `--check-png`."""
    if not avatar.startswith(PNG_SIGNATURE):
        raise CardError("not a PNG (bad signature)")
    offset, end = len(PNG_SIGNATURE), len(avatar)
    while offset + 8 <= end:
        (length,) = struct.unpack(">I", avatar[offset : offset + 4])
        ctype = avatar[offset + 4 : offset + 8]
        data = avatar[offset + 8 : offset + 8 + length]
        if ctype == b"tEXt" and data.startswith(b"chara\x00"):
            return json.loads(base64.b64decode(data[len(b"chara\x00") :]).decode("utf-8"))
        offset += 4 + 4 + length + 4
    raise CardError("no chara chunk in this PNG")


def generate_card(
    notes: dict[str, Any],
    endpoint: str,
    model: str,
    api_key: str | None,
    temperature: float,
    max_attempts: int = 3,
) -> dict[str, Any]:
    """Ask the model for the draft, repairing rejections, up to max_attempts.

    Two failure classes earn a targeted correction and another attempt:

      * the reply is not one JSON object;
      * the JSON parses but `build_card`/`validate_card` rejects it — the
        live case is a model that returns FEWER alternate greetings than
        asked (Lumimaid twice returned 1 for 2), or empty required prose.

    The correction quotes the rejection reason, and the failed reply stays
    in the history so the model can see what to fix. Anything else —
    unreachable endpoint, HTTP error — raises immediately: retrying those
    is waiting, not repairing.
    """
    if max_attempts < 1:
        raise CardError("--max-attempts must be at least 1")
    messages = build_prompt(notes)
    last_error: CardError | None = None
    for attempt in range(1, max_attempts + 1):
        if attempt > 1:
            _log(f"attempt {attempt}/{max_attempts}: re-asking after: {last_error}")
        raw = post_chat_completions(endpoint, model, messages, api_key, temperature)
        try:
            drafted = coerce_json_object(raw)
        except CardError as exc:
            last_error = exc
            messages = messages + [
                {"role": "assistant", "content": raw},
                {"role": "user", "content": "That was not one JSON object. Reply again with ONLY the JSON object, no fences, no commentary."},
            ]
            continue
        try:
            card = build_card(notes, drafted)
            validate_card(card)
            return card
        except CardError as exc:
            last_error = exc
            messages = messages + [
                {"role": "assistant", "content": raw},
                {"role": "user", "content": f"That draft was rejected: {exc}. Reply again with ONLY the corrected JSON object, no fences, no commentary."},
            ]
    raise last_error or CardError("model produced no usable draft")


# ── writing ───────────────────────────────────────────────────────────────────


def write_card_file(card: dict[str, Any], path: str, force: bool) -> None:
    if os.path.exists(path) and not force:
        raise CardError(f"{path} exists; pass --force to overwrite")
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(card, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
    _log(f"wrote {path}")


def write_into_data_root(
    card: dict[str, Any], data_root: str, handle: str, png: bytes | None, force: bool
) -> list[str]:
    """Seed the card where the server reads characters from.

    Characters live at `<dataRoot>/<handle>/characters/<Name>.json` (the
    seeder never touches them — they are the operator's own writing, see
    COVERAGE.md §5 — so this is the one sanctioned writer besides the UI).
    """
    stem = safe_filename(card["data"]["name"])
    target_dir = os.path.join(os.path.abspath(data_root), handle, "characters")
    os.makedirs(target_dir, exist_ok=True)
    written = []
    json_path = os.path.join(target_dir, stem + ".json")
    if os.path.exists(json_path) and not force:
        raise CardError(f"{json_path} exists; pass --force to overwrite")
    with open(json_path, "w", encoding="utf-8") as fh:
        json.dump(card, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    written.append(json_path)
    if png is not None:
        png_path = os.path.join(target_dir, stem + ".png")
        if os.path.exists(png_path) and not force:
            raise CardError(f"{png_path} exists; pass --force to overwrite")
        with open(png_path, "wb") as fh:
            fh.write(png)
        written.append(png_path)
    for p in written:
        _log(f"wrote {p}")
    return written


# ── main ──────────────────────────────────────────────────────────────────────


def build_arg_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        description="Guided character-card generator for SillyTavern (TavernCard v2).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Endpoint env: ST_CHARGEN_ENDPOINT/ST_CHARGEN_MODEL/ST_CHARGEN_API_KEY override the defaults; flags override env.",
    )
    ap.add_argument("--endpoint", default=os.environ.get("ST_CHARGEN_ENDPOINT", DEFAULT_ENDPOINT),
                    help=f"OpenAI-compatible base URL (default: env ST_CHARGEN_ENDPOINT or {DEFAULT_ENDPOINT})")
    ap.add_argument("--model", default=os.environ.get("ST_CHARGEN_MODEL", DEFAULT_MODEL),
                    help=f"Chat model id (default: env ST_CHARGEN_MODEL or {DEFAULT_MODEL})")
    ap.add_argument("--api-key", default=os.environ.get("ST_CHARGEN_API_KEY"),
                    help="Bearer token, if the endpoint needs one (Ollama does not)")
    ap.add_argument("--api-key-file", default=os.environ.get("ST_CHARGEN_API_KEY_FILE"),
                    help="File holding the bearer token (read at runtime, never env-visible)")
    ap.add_argument("--temperature", type=float, default=0.2,
                    help="Sampling temperature for the draft (default 0.2: steady prose)")
    ap.add_argument("--max-attempts", type=int, default=3,
                    help="Model calls before giving up; a rejected draft is re-asked with the reason quoted (default 3)")
    ap.add_argument("--non-interactive", action="store_true",
                    help="Never prompt; every answer must come from flags")
    ap.add_argument("--dry-run", action="store_true",
                    help="Skip the model entirely; build the card from the answers with template prose")
    # Answers as flags (each mirrors one questionnaire item):
    ap.add_argument("--concept", default=os.environ.get("ST_CHARGEN_CONCEPT", ""))
    ap.add_argument("--name", default="")
    ap.add_argument("--personality-notes", default="")
    ap.add_argument("--scenario-notes", default="")
    ap.add_argument("--speech-notes", default="")
    ap.add_argument("--greeting-seed", default="")
    ap.add_argument("--alt-greetings-count", default="2")
    ap.add_argument("--tags", default="")
    ap.add_argument("--creator", default=os.environ.get("ST_CHARGEN_CREATOR", DEFAULT_CREATOR))
    ap.add_argument("--nsfw-ok", action="store_true")
    # Outputs:
    ap.add_argument("--out", default="",
                    help="Write the v2 JSON card here (default: <Name>.json in cwd)")
    ap.add_argument("--png", default="",
                    help="Avatar PNG to embed the card into; writes <stem>.png beside --out")
    ap.add_argument("--to-data-root", default="",
                    help="Also seed into a server data root (uses --handle for the account dir)")
    ap.add_argument("--handle", default="default-user",
                    help="Account handle for --to-data-root (default: default-user)")
    ap.add_argument("--force", action="store_true", help="Overwrite existing outputs")
    ap.add_argument("--check-png", default="",
                    help="Validate: read the embedded card back out of this PNG and exit")
    return ap


def read_api_key(args: argparse.Namespace) -> str | None:
    if args.api_key_file:
        try:
            with open(args.api_key_file, "r", encoding="utf-8") as fh:
                return fh.read().strip() or None
        except OSError as exc:
            raise CardError(f"cannot read --api-key-file: {exc}") from exc
    return args.api_key or None


def main(argv: list[str] | None = None) -> int:
    ap = build_arg_parser()
    args = ap.parse_args(argv)

    if args.check_png:
        try:
            with open(args.check_png, "rb") as fh:
                card = extract_card_from_png(fh.read())
            validate_card(card)
        except (CardError, OSError, ValueError) as exc:
            _log(f"invalid: {exc}")
            return 2
        _log(f"{args.check_png} holds a valid {CARD_SPEC} card for {card['data'].get('name')!r}")
        return 0

    pre = {
        "concept": args.concept,
        "name": args.name,
        "personality_notes": args.personality_notes,
        "scenario_notes": args.scenario_notes,
        "speech_notes": args.speech_notes,
        "greeting_seed": args.greeting_seed,
        "alt_greetings_count": args.alt_greetings_count,
        "tags": args.tags,
        "creator": args.creator,
        "nsfw_ok": "yes" if args.nsfw_ok else "",
    }
    try:
        if args.non_interactive:
            missing = [q["key"] for q in QUESTIONS if q.get("required") and not pre.get(q["key"])]
            if missing:
                raise CardError(f"--non-interactive needs {', '.join('--' + m.replace('_', '-') for m in missing)}")
            answers = pre
        else:
            answers = ask_interactive(pre)
        notes = normalise_answers(answers)

        if args.dry_run:
            _log("dry run: no model call, building from answers alone")
            drafted = draft_from_template(notes)
            card = build_card(notes, drafted)
            validate_card(card)
        else:
            api_key = read_api_key(args)
            _log(f"asking {args.model} at {args.endpoint} ...")
            card = generate_card(notes, args.endpoint, args.model, api_key, args.temperature, args.max_attempts)

        out = args.out or (safe_filename(notes["name"]) + ".json")
        write_card_file(card, out, args.force)

        png_bytes: bytes | None = None
        if args.png:
            with open(args.png, "rb") as fh:
                avatar = fh.read()
            png_bytes = embed_card_in_png(card, avatar)
            png_out = os.path.join(
                os.path.dirname(os.path.abspath(out)) or ".",
                os.path.splitext(os.path.basename(out))[0] + ".png",
            )
            if os.path.exists(png_out) and not args.force:
                raise CardError(f"{png_out} exists; pass --force to overwrite")
            with open(png_out, "wb") as fh:
                fh.write(png_bytes)
            _log(f"wrote {png_out} (card embedded as tEXt chara)")

        if args.to_data_root:
            write_into_data_root(card, args.to_data_root, args.handle, png_bytes, args.force)

        _log(f"done: {card['data']['name']} — {len(card['data']['alternate_greetings'])} alt greetings, tags: {', '.join(card['data']['tags']) or 'none'}")
        return 0
    except CardError as exc:
        _log(f"error: {exc}")
        return 1
    except KeyboardInterrupt:
        _log("cancelled")
        return 130


if __name__ == "__main__":
    sys.exit(main())
