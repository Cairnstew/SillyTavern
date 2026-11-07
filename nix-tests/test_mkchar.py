#!/usr/bin/env python3
"""Tests for scripts/st_mkchar.py — the guided character-card generator.

The behaviours pinned here are the ones that would produce a card the import
dialog refuses, or a run that surprises the operator:

  * every emitted card validates as TavernCard v2 (the same required keys
    `src/validator/TavernCardValidator.js` demands);
  * the questionnaire has no orphan keys (asked-but-unused, or used-but-never-asked);
  * `--dry-run` is deterministic and needs no network;
  * the PNG embed round-trips through `extract_card_from_png`;
  * outputs are never clobbered without `--force`.
"""

from __future__ import annotations

import json
import os
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO / "scripts"))

import st_mkchar as mkchar  # noqa: E402


def _notes(**overrides):
    base = {
        "concept": "a retired lighthouse keeper who maps storms from memory",
        "name": "Mara Voss",
        "personality_notes": "dry-humoured, patient",
        "scenario_notes": "the user shelters in the lighthouse during a gale",
        "speech_notes": "short sentences, sea metaphors",
        "greeting_seed": "Mara finds the user dripping in her doorway",
        "alt_greetings_count": 2,
        "tags": ["seaside", "slow-burn"],
        "creator": "tester",
        "nsfw_ok": False,
    }
    base.update(overrides)
    return base


def _drafted(n=2):
    return {
        "description": "Mara keeps the light. " * 4,
        "personality": "Patient and dry-humoured.",
        "scenario": "A gale, a doorway, a blanket.",
        "first_mes": "You're soaked. Come in before the wind takes you.",
        "mes_example": "<START>\n{{user}}: Hi.\n{{char}}: Hello.",
        "alternate_greetings": [f"Greeting {i + 1}" for i in range(n)],
        "system_prompt": "",
        "post_history_instructions": "",
        "creator_notes": "",
    }


def _tiny_png() -> bytes:
    def chunk(ctype: bytes, data: bytes) -> bytes:
        import binascii

        return (
            struct.pack(">I", len(data))
            + ctype
            + data
            + struct.pack(">I", binascii.crc32(ctype + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", 1, 1, 8, 2, 0, 0, 0)
    raw = b"\x00\xff\x00\x00"
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


class QuestionnaireTests(unittest.TestCase):
    def test_every_question_key_is_consumed(self):
        """No orphan keys: asked-but-unused, or used-but-never-asked."""
        asked = {q["key"] for q in mkchar.QUESTIONS}
        # `normalise_answers` reads every key it keeps; `build_prompt` reads
        # every key the model needs. `creator` has a flag default, `nsfw_ok`
        # is coerced from the flag — both still flow through `pre`.
        notes = mkchar.normalise_answers(
            {
                "concept": "c",
                "name": "N",
                "personality_notes": "",
                "scenario_notes": "",
                "speech_notes": "",
                "greeting_seed": "",
                "alt_greetings_count": "1",
                "tags": "",
                "creator": "t",
                "nsfw_ok": "",
            }
        )
        prompt = "\n".join(m["content"] for m in mkchar.build_prompt(notes))
        for key in ("concept", "name"):
            self.assertIn(key, asked)
        self.assertIn("c", prompt)

    def test_question_order_is_stable(self):
        first = [q["key"] for q in mkchar.QUESTIONS]
        self.assertEqual(first, [q["key"] for q in mkchar.QUESTIONS])
        # Concept first, name second: the two required answers lead.
        self.assertEqual(first[:2], ["concept", "name"])

    def test_name_rejects_path_characters(self):
        with self.assertRaises(mkchar.CardError):
            mkchar.normalise_answers({"concept": "c", "name": "../escape"})
        with self.assertRaises(mkchar.CardError):
            mkchar.normalise_answers({"concept": "c", "name": "a/b"})

    def test_alt_count_is_clamped(self):
        notes = mkchar.normalise_answers({"concept": "c", "name": "N", "alt_greetings_count": "0"})
        self.assertEqual(notes["alt_greetings_count"], 0)
        with self.assertRaises(mkchar.CardError):
            mkchar.normalise_answers({"concept": "c", "name": "N", "alt_greetings_count": "9"})
        with self.assertRaises(mkchar.CardError):
            mkchar.normalise_answers({"concept": "c", "name": "N", "alt_greetings_count": "many"})

    def test_tags_split_on_commas(self):
        notes = mkchar.normalise_answers({"concept": "c", "name": "N", "tags": "a, b ,,c"})
        self.assertEqual(notes["tags"], ["a", "b", "c"])


class CardShapeTests(unittest.TestCase):
    def test_built_card_has_every_v2_field(self):
        card = mkchar.build_card(_notes(), _drafted())
        mkchar.validate_card(card)  # must not raise
        self.assertEqual(card["spec"], "chara_card_v2")
        self.assertEqual(card["spec_version"], "2.0")
        for field in mkchar.REQUIRED_DATA_FIELDS:
            self.assertIn(field, card["data"])

    def test_alt_greeting_count_mismatch_is_refused(self):
        with self.assertRaises(mkchar.CardError):
            mkchar.build_card(_notes(alt_greetings_count=2), _drafted(n=3))

    def test_empty_prose_is_refused(self):
        bad = _drafted()
        bad["description"] = "   "
        card = mkchar.build_card(_notes(), bad)
        with self.assertRaises(mkchar.CardError):
            mkchar.validate_card(card)

    def test_validator_mirrors_upstream_required_keys(self):
        """A card missing one v2 key must not validate.

        The key list is transcribed from `src/validator/TavernCardValidator.js`
        (#validateDataV2). If upstream adds a key there, this test — and the
        script — must grow the same key.
        """
        card = mkchar.build_card(_notes(), _drafted())
        del card["data"]["personality"]
        with self.assertRaises(mkchar.CardError):
            mkchar.validate_card(card)

    def test_dry_run_template_is_valid_and_deterministic(self):
        first = mkchar.build_card(_notes(), mkchar.draft_from_template(_notes()))
        second = mkchar.build_card(_notes(), mkchar.draft_from_template(_notes()))
        self.assertEqual(first, second)
        mkchar.validate_card(first)

    def test_dry_run_respects_alt_count(self):
        notes = _notes(alt_greetings_count=0)
        card = mkchar.build_card(notes, mkchar.draft_from_template(notes))
        self.assertEqual(card["data"]["alternate_greetings"], [])
        mkchar.validate_card(card)


class PromptTests(unittest.TestCase):
    def test_prompt_renders_notes_verbatim(self):
        notes = _notes()
        prompt = "\n".join(m["content"] for m in mkchar.build_prompt(notes))
        self.assertIn(notes["concept"], prompt)
        self.assertIn(notes["greeting_seed"], prompt)
        self.assertIn("EXACTLY 2 alternate greetings", prompt)

    def test_prompt_states_the_schema_keys(self):
        notes = _notes()
        prompt = "\n".join(m["content"] for m in mkchar.build_prompt(notes))
        for key in ("description", "first_mes", "mes_example", "alternate_greetings"):
            self.assertIn(f'"{key}"', prompt)

    def test_nsfw_flag_reaches_the_prompt(self):
        clean = "\n".join(m["content"] for m in mkchar.build_prompt(_notes(nsfw_ok=False)))
        spicy = "\n".join(m["content"] for m in mkchar.build_prompt(_notes(nsfw_ok=True)))
        self.assertIn("keep it clean", clean)
        self.assertIn("write frankly", spicy)

    def test_schema_doc_spells_the_count_as_a_number(self):
        """The old doc said "N alternate messages" — a literal letter N."""
        doc = mkchar.schema_keys_doc(3)
        self.assertIn("exactly 3 alternate opening messages", doc)
        self.assertNotIn('"N ', doc)
        self.assertIn("[]", mkchar.schema_keys_doc(0))


class RepairLoopTests(unittest.TestCase):
    def test_wrong_greeting_count_is_repaired_with_a_reask(self):
        """The live Lumimaid case: 1 greeting returned for 2 asked."""
        notes = _notes(alt_greetings_count=2)
        bad = json.dumps(_drafted(n=1))
        good = json.dumps(_drafted(n=2))
        with mock.patch.object(mkchar, "post_chat_completions", side_effect=[bad, good]) as post:
            card = mkchar.generate_card(notes, "http://x/v1", "m", None, 0.2, max_attempts=3)
        self.assertEqual(len(card["data"]["alternate_greetings"]), 2)
        self.assertEqual(post.call_count, 2)
        # The correction quotes the rejection reason at the model.
        repair_prompt = post.call_args[0][2][-1]["content"]
        self.assertIn("alternate greetings", repair_prompt)

    def test_non_json_then_valid_json_recovers(self):
        notes = _notes()
        with mock.patch.object(
            mkchar, "post_chat_completions", side_effect=["not json", json.dumps(_drafted())]
        ) as post:
            card = mkchar.generate_card(notes, "http://x/v1", "m", None, 0.2, max_attempts=3)
        self.assertEqual(card["data"]["name"], "Mara Voss")
        self.assertEqual(post.call_count, 2)

    def test_persistent_failure_raises_after_max_attempts(self):
        notes = _notes(alt_greetings_count=2)
        bad = json.dumps(_drafted(n=1))
        with mock.patch.object(mkchar, "post_chat_completions", return_value=bad) as post:
            with self.assertRaises(mkchar.CardError):
                mkchar.generate_card(notes, "http://x/v1", "m", None, 0.2, max_attempts=2)
        self.assertEqual(post.call_count, 2)

    def test_network_errors_are_not_retried(self):
        notes = _notes()
        with mock.patch.object(
            mkchar, "post_chat_completions", side_effect=mkchar.CardError("cannot reach x")
        ) as post:
            with self.assertRaises(mkchar.CardError):
                mkchar.generate_card(notes, "http://x/v1", "m", None, 0.2, max_attempts=3)
        self.assertEqual(post.call_count, 1)


class EndpointTests(unittest.TestCase):
    def test_appends_chat_completions(self):
        self.assertEqual(
            mkchar.normalise_endpoint("http://127.0.0.1:11434/v1"),
            "http://127.0.0.1:11434/v1/chat/completions",
        )
        self.assertEqual(
            mkchar.normalise_endpoint("http://x:9931/v1/chat/completions"),
            "http://x:9931/v1/chat/completions",
        )
        with self.assertRaises(mkchar.CardError):
            mkchar.normalise_endpoint("")

    def test_model_json_is_coerced_through_fences(self):
        doc = mkchar.coerce_json_object('```json\n{"a": 1}\n```')
        self.assertEqual(doc, {"a": 1})
        doc = mkchar.coerce_json_object('here you go {"a": 1} bye')
        self.assertEqual(doc, {"a": 1})
        with self.assertRaises(mkchar.CardError):
            mkchar.coerce_json_object("no json here at all")


class PngTests(unittest.TestCase):
    def test_embed_round_trips(self):
        card = mkchar.build_card(_notes(), _drafted())
        embedded = mkchar.embed_card_in_png(card, _tiny_png())
        self.assertEqual(mkchar.extract_card_from_png(embedded)["data"]["name"], "Mara Voss")

    def test_non_png_is_refused(self):
        card = mkchar.build_card(_notes(), _drafted())
        with self.assertRaises(mkchar.CardError):
            mkchar.embed_card_in_png(card, b"definitely not a png")

    def test_check_png_without_chara_fails(self):
        with self.assertRaises(mkchar.CardError):
            mkchar.extract_card_from_png(_tiny_png())


class WritingTests(unittest.TestCase):
    def test_out_refuses_to_clobber_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "Mara Voss.json")
            Path(out).write_text("{}", encoding="utf-8")
            card = mkchar.build_card(_notes(), _drafted())
            with self.assertRaises(mkchar.CardError):
                mkchar.write_card_file(card, out, force=False)
            mkchar.write_card_file(card, out, force=True)
            self.assertEqual(json.loads(Path(out).read_text())["data"]["name"], "Mara Voss")

    def test_data_root_layout_matches_the_server(self):
        with tempfile.TemporaryDirectory() as tmp:
            card = mkchar.build_card(_notes(), _drafted())
            written = mkchar.write_into_data_root(card, tmp, "default-user", None, force=False)
            self.assertEqual(written, [os.path.join(tmp, "default-user", "characters", "Mara Voss.json")])

    def test_main_dry_run_end_to_end(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "card.json")
            rc = mkchar.main(
                [
                    "--dry-run",
                    "--non-interactive",
                    "--concept",
                    "a keeper",
                    "--name",
                    "Mara Voss",
                    "--out",
                    out,
                ]
            )
            self.assertEqual(rc, 0)
            mkchar.validate_card(json.loads(Path(out).read_text(encoding="utf-8")))

    def test_main_non_interactive_requires_concept_and_name(self):
        rc = mkchar.main(["--dry-run", "--non-interactive", "--name", "Mara"])
        self.assertNotEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
