"""Score/schema regressions. Run: python -B -m unittest discover -s visualizer -p score_test.py -v"""
import copy
from collections import Counter
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

if __package__:
    from . import score
else:
    import score


class ScoreTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tables, cls.arrangement, cls.defines = score._inputs()
        cls.result = score.build_score()
        cls.row = cls.result["row_seconds"]

    def events(self, track):
        return [n for n in self.result["notes"] if n["track"] == track]

    def row_of(self, event):
        return round(event["start"] / self.row)

    def test_schema_clock_and_sorted_events(self):
        result = self.result
        self.assertEqual(set(result), {"duration", "notes", "drums", "sections", "row_seconds", "bars"})
        self.assertEqual(result["duration"], 7680000 / 44100)
        self.assertEqual(result["row_seconds"], 5000 / 44100)
        self.assertEqual(result["bars"], 96)
        self.assertEqual({n["track"] for n in result["notes"]}, score.TRACKS)
        for note in result["notes"]:
            self.assertEqual(set(note), {"track", "pitch", "start", "end", "velocity"})
            self.assertIs(type(note["pitch"]), int)
            self.assertIn(note["pitch"], range(128))
            self.assertTrue(0 <= note["start"] < note["end"] <= result["duration"])
        for drum in result["drums"]:
            self.assertEqual(set(drum), {"track", "start", "velocity"})
            self.assertIn(drum["track"], score.DRUM_TRACKS)
        for key in ("notes", "drums", "sections"):
            self.assertEqual([e["start"] for e in result[key]],
                             sorted(e["start"] for e in result[key]))
        json.dumps(result, allow_nan=False)
        score._validate(result)

    def test_bake_equivalence_is_checked_and_failure_is_explicit(self):
        stale = copy.deepcopy(self.arrangement)
        stale["tables"]["g_sqSolo"][1][25*32] += 1
        with patch.object(score, "_arrangement", return_value=stale):
            with self.assertRaisesRegex(ValueError, "differs"):
                score.build_score()
        wrong_clock = copy.deepcopy(self.arrangement)
        wrong_clock["spr"] += 1
        with patch.object(score, "_arrangement", return_value=wrong_clock):
            with self.assertRaisesRegex(ValueError, "Clock mismatch"):
                score.build_score()

    def test_direct_note_attacks_preserve_midi_register_and_restrikes(self):
        for track, table in (("lead", "g_sqLead"), ("solo", "g_sqSolo"),
                             ("harmony", "g_sqHarm")):
            expected = [(k, pitch+12) for k, pitch in enumerate(self.tables[table])
                        if pitch >= 0 and (track != "harmony" or self.tables["g_sqSolo"][k] >= 0)]
            self.assertEqual([(self.row_of(n), n["pitch"]) for n in self.events(track)], expected)
        self.assertEqual([n["pitch"] for n in self.events("solo")
                          if self.row_of(n) == 40*32], [95])
        self.assertFalse(any(39*32+16 <= self.row_of(n) < 39*32+28 for n in self.events("solo")))
        self.assertEqual(sum(n["start"] >= 16*32*self.row and n["start"] < 40*32*self.row
                             for n in self.events("solo")),
                         sum(n >= 0 for n in self.tables["g_sqSolo"][16*32:40*32]))
        orphan = copy.deepcopy(self.tables)
        orphan["g_sqHarm"][0] = 69
        result = score._extract(orphan, self.arrangement, self.defines)
        self.assertFalse(any(n["track"] == "harmony" and n["start"] == 0 for n in result["notes"]))

    def test_bass_folding_and_guitar_chord_not_oscillator_duplicates(self):
        bass = self.events("bass")
        self.assertEqual(len(bass), sum(n >= 0 for n in self.tables["g_sqBass"]))
        for note in bass:
            k = self.row_of(note)
            original = self.tables["g_sqBass"][k] + 12
            self.assertEqual(note["pitch"] % 12, original % 12)
            if self.tables["g_sqSyn"][k//32]:
                hz = 440 * 2 ** ((note["pitch"]-69)/12)
                self.assertTrue(58 <= hz <= 150)
            else:
                self.assertEqual(note["pitch"], original)
        for k, pitch in enumerate(self.tables["g_sqGtr"]):
            actual = [n["pitch"] for n in self.events("guitar") if self.row_of(n) == k]
            self.assertEqual(actual, [] if pitch < 0 else [pitch+12, pitch+19])

    def test_arp_and_bell_trigger_conditions(self):
        arp = self.events("arp")
        self.assertEqual(len(arp), 6*16)
        self.assertEqual([self.row_of(n) for n in arp], list(range(2*32, 8*32, 2)))
        self.assertEqual([n["pitch"] for n in arp[:8]], [57,60,64,69,57,60,64,69])
        self.assertEqual([n["velocity"] for n in arp[:4]], [1.0,.62,.62,.62])
        bells = self.events("bell")
        self.assertEqual([(self.row_of(n)//32, n["pitch"], n["velocity"]) for n in bells],
                         [(0,81,.55), (46,79,.55)])

    def test_sustained_voicings_and_unchanged_order_boundaries(self):
        organ = [n for n in self.events("organ") if n["start"] == 0]
        self.assertEqual([n["pitch"] for n in organ], [57,60,64])
        self.assertTrue(all(n["end"] == 16*self.row for n in organ))
        pad = [n for n in self.events("pad") if self.row_of(n) == 2*32]
        self.assertEqual([n["pitch"] for n in pad], [60,64,69])
        altered = copy.deepcopy(self.tables)
        # A constant Am pad across two orders is one chord, not eight triggers.
        altered["g_sqRoot"][2*4:4*4] = [9]*8
        altered["g_sqType"][2*4:4*4] = [0]*8
        result = score._extract(altered, self.arrangement, self.defines)
        held = [n for n in result["notes"] if n["track"] == "pad" and n["start"] == 64*self.row]
        self.assertEqual(len(held), 3)
        self.assertTrue(all(n["end"] == 128*self.row for n in held))
        self.assertFalse(any(n["track"] == "pad" and 64*self.row < n["start"] < 128*self.row
                             for n in result["notes"]))

    def test_drum_decoding_has_no_invented_hat_or_echo_triggers(self):
        expected = Counter()
        for k, code in enumerate(self.tables["g_sqDrum"]):
            if code in (1,6,7): expected[(k,"kick",1.0)] += 1
            if code in (2,7): expected[(k,"snare",.85)] += 1
            if code in (3,4): expected[(k,"hat",.30 if code == 3 else .55)] += 1
            if code in (5,6): expected[(k,"crash",.95)] += 1
        self.assertEqual(Counter((self.row_of(n),n["track"],n["velocity"])
                                 for n in self.result["drums"]), expected)

    def test_unused_chip_arp_uses_exact_tick_boundaries(self):
        altered = copy.deepcopy(self.tables)
        altered["g_sqArpOct"][0] = 36
        result = score._extract(altered, self.arrangement, self.defines)
        notes = [n for n in result["notes"] if n["track"] == "arp" and n["start"] < 32*self.row]
        self.assertEqual(len(notes), 32*6)
        self.assertEqual([n["pitch"] for n in notes[:6]], [57,60,64,57,60,64])
        self.assertEqual([round((n["end"]-n["start"])*44100) for n in notes[:6]],
                         [833,833,834,833,833,834])
        self.assertEqual(notes[-1]["end"], 160000/44100)

    def test_visual_gates_and_section_coverage(self):
        for track, cap in (("lead",2), ("bass",4), ("solo",4), ("harmony",4), ("bell",16)):
            for note in self.events(track):
                self.assertLessEqual(note["end"]-note["start"], cap*self.row+1e-12)
        sections = self.result["sections"]
        self.assertEqual([s["name"] for s in sections],
                         ["INTRO","SYNTHWAVE","METAL VERSE","CHORUS","SOLO","ARRIVAL","OUTRO"])
        self.assertEqual(sections[0]["start"],0)
        self.assertEqual(sections[-1]["end"],self.result["duration"])
        for a,b in zip(sections,sections[1:]):
            self.assertEqual(a["end"],b["start"])

    def test_import_has_no_export_or_subprocess_side_effect(self):
        spec = importlib.util.spec_from_file_location("score_import_probe", Path(score.__file__))
        module = importlib.util.module_from_spec(spec)
        with patch.object(Path,"write_text",side_effect=AssertionError("import wrote text")), \
             patch.object(Path,"write_bytes",side_effect=AssertionError("import wrote bytes")), \
             patch.object(score.subprocess,"run",side_effect=AssertionError("import launched a process")):
            spec.loader.exec_module(module)
        self.assertTrue(callable(module.build_score))


if __name__ == "__main__":
    unittest.main()
