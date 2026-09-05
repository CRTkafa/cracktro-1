"""Score/API regression checks; no build, rendering, or audio playback.

Run: python -m unittest discover -s tools -p test_music_form.py -v
"""
import re
import unittest
import tempfile
from unittest.mock import patch
from pathlib import Path
import arrange_v11 as A
import motif as M
import export_song as E


class MusicFormTests(unittest.TestCase):
    def test_exporter_preserves_current_score_and_check_is_read_only(self):
        with tempfile.TemporaryDirectory(prefix="crtk-score-test-") as tmp:
            output = Path(tmp) / "score.h"
            self.assertEqual(E.main(["--output", str(output)]), 0)
            self.assertEqual(output.read_text(encoding="utf-8"), A.header())
            with patch.object(Path, "write_text", side_effect=AssertionError("check wrote a file")):
                self.assertEqual(E.main(["--check", "--output", str(output)]), 0)
                self.assertEqual(E.main(["--check", "--output", str(Path(tmp)/"missing.h")]), 1)
            output.write_text("obsolete v10 score", encoding="utf-8")
            with patch.object(Path, "write_text", side_effect=AssertionError("check wrote a file")):
                self.assertEqual(E.main(["--check", "--output", str(output)]), 1)

    def test_exact_form_and_clock(self):
        self.assertEqual([(n,a,b) for n,a,b,_ in A.SECTIONS], [
            ("INTRO",0,1), ("SYNTHWAVE",2,7), ("METAL VERSE",8,11),
            ("CHORUS",12,15), ("SOLO",16,39), ("ARRIVAL",40,45), ("OUTRO",46,47)])
        self.assertEqual([o for _,a,b,_ in A.SECTIONS for o in range(a,b+1)], list(range(48)))
        source = (A.HERE.parent / "synth.h").read_text()
        for name,value in (("SPR",5000),("SRATE",44100),("TPR",6),("ROWS",32),("ORDERS",48)):
            self.assertRegex(source, rf"#define\s+{name}\s+{value}\b")
        self.assertEqual(sum((t+1)*5000//6 - t*5000//6 for t in range(6)),5000)
        self.assertEqual(A.ORDERS*A.ROWS*A.SPR,7680000)
        self.assertAlmostEqual(A.ORDERS*A.ROWS*A.SPR/A.SRATE,174.149659864,places=8)
        self.assertEqual(A.sect[:2], [0,0])
        self.assertEqual(A.sect[46:], [10,10])
        self.assertTrue(all(s not in (0,7,10) for s in A.sect[2:46]))

    def test_no_duplicate_musical_orders(self):
        # Exclude drums, metadata, gain and risers: percussion or a new label
        # must not disguise a repeated arrangement. Include voiced harmony.
        signatures = {}
        for o in range(48):
            sig = tuple(tuple(lane[o]) for lane in
                        (A.lead,A.solo,A.harm,A.bass,A.gtr,A.hold,A.root,A.ctyp))
            sig += (A.arpo[o], A.orgm[o], A.syn[o])
            self.assertNotIn(sig,signatures, f"duplicate orders {signatures.get(sig)} and {o}")
            signatures[sig] = o
        for lane,orders in ((A.solo,range(16,40)),(A.solo,range(40,46)),(A.lead,range(12,16))):
            phrases = [tuple(lane[o]) for o in orders]
            self.assertEqual(len(phrases),len(set(phrases)))

    def test_dense_runs_and_lyrical_contrast(self):
        counts = [sum(n>=0 for n in A.solo[o]) for o in range(16,40)]
        self.assertGreaterEqual(sum(n>=30 for n in counts),9)
        self.assertGreaterEqual(len(set(counts)),10)
        rhythms = {tuple(r for r,n in enumerate(A.solo[o]) if n>=0) for o in range(16,40)}
        self.assertGreaterEqual(len(rhythms),14)
        for o in (*range(25,31),36,37,38):
            longest = current = 0
            for n in A.solo[o]:
                current = current+1 if n>=0 else 0
                longest = max(longest,current)
            self.assertGreaterEqual(longest,28)
        self.assertLess(max(counts[:4]),min(counts[4:9]))
        # Lyrical figures explicitly refresh selected notes; rests aren't ties.
        for o in range(20,25):
            pitches = [n for n in A.solo[o] if n>=0]
            self.assertTrue(any(a==b for a,b in zip(pitches,pitches[1:])))
        self.assertEqual(A.solo[39][16:28],[-1]*12)
        self.assertTrue(all(n>=0 for n in A.solo[39][28:32]))

    def test_v8_contour_preserved_without_register_clamp(self):
        expected = [57,59,60,62,64,65,67,69,67,65,64,62,60,59,57,55,
                    57,60,64,69,72,69,64,60,57,59,60,64,69,67,64,57]
        self.assertEqual(A.solo[25],expected)
        self.assertEqual(max(A.solo[38]),81)
        self.assertEqual(A.solo[40][0],83)
        self.assertEqual(M.deg(0),57)  # A4 is MIDI 69 minus 12.

    def test_pitch_scale_and_bass_riff_consonance(self):
        for o in range(48):
            key = 9 + (2 if o>=40 else 0)
            scale = {(key+n)%12 for n in M.MIN_IV}
            for lane in (A.lead,A.solo,A.harm,A.bass,A.gtr):
                self.assertEqual(len(lane[o]),32)
                for n in lane[o]:
                    self.assertTrue(n==-1 or 0<=n<=127)
                    if n>=0: self.assertIn(n%12,scale)
            for ci,rt in enumerate(A.root[o]):
                chord = {(rt+n)%12 for n in (0,4 if A.ctyp[o][ci] else 3,7)}
                self.assertTrue(chord <= scale)
            for r in range(32):
                rt = A.root[o][r//8]
                if A.bass[o][r]>=0: self.assertEqual(A.bass[o][r]%12,rt)
                if A.gtr[o][r]>=0:
                    self.assertIn((A.gtr[o][r]-rt)%12,(0,7))
                    self.assertIn(A.gtr[o][r]%12,scale)
                    self.assertIn((A.gtr[o][r]+7)%12,scale)
                    self.assertGreaterEqual(A.gtr[o][r],21)
        for o,r in ((8,26),(9,27),(10,28),(11,16),(11,20)):
            self.assertEqual(A.gtr[o][r]%12,4)  # E power chord, not B + F#

    def test_drum_codes_preserve_kicks(self):
        kick_codes, snare_codes, crash_codes = {1,6,7}, {2,7}, {5,6}
        crashes = []
        for o in range(48):
            self.assertEqual(len(A.drum[o]),32)
            for r,code in enumerate(A.drum[o]):
                self.assertIn(code,range(8))
                if code in crash_codes:
                    crashes.append((o,r))
                    self.assertIn(code,kick_codes)
                if code==7:
                    self.assertIn(o,range(2,8))
                    self.assertIn(r,(4,12,20,28))
            if 2<=o<=7:
                for r in range(0,32,4):
                    self.assertIn(A.drum[o][r],kick_codes)
                for r in (4,12,20,28):
                    self.assertIn(A.drum[o][r],snare_codes)
        self.assertEqual(crashes,[(o,0) for o in (2,8,12,20,25,36,40)])

    def test_one_foreground_owner(self):
        for o in range(48):
            active = [any(n>=0 for n in lane[o]) for lane in (A.lead,A.solo,A.gtr)]
            self.assertLessEqual(sum(active),1)
            self.assertEqual(A.arpo[o],-1)  # no extra chip arp over synth arp
            if A.orgm[o]==2 and active[1]:
                self.assertIn(o,range(31,36))
                self.assertGreaterEqual(min(n for n in A.solo[o] if n>=0),69)
                self.assertFalse(active[0] or active[2])
            if A.syn[o]:
                self.assertIn(o,range(2,8))
                self.assertFalse(any(active))
                self.assertEqual(A.orgm[o],0)

    def test_generated_header_matches_runtime_api(self):
        text = (A.HERE.parent / "song_data.h").read_text(encoding="utf-8")
        self.assertEqual(text,A.header())
        parsed = {}
        for typ,name,body in re.findall(r"static const (signed char|unsigned char|short) (g_sq\w+)\[\] = \{(.*?)\};",text,re.S):
            parsed[name] = (typ,list(map(int,re.findall(r"-?\d+",body))))
        expected_names = {"g_sqLead","g_sqSolo","g_sqHarm","g_sqBass","g_sqGtr","g_sqHold",
                          "g_sqDrum","g_sqRoot","g_sqType","g_sqArpOct","g_sqOrgMode",
                          "g_sqRiser","g_sqGain","g_sqSyn","g_sqSect"}
        self.assertEqual(set(parsed),expected_names)
        source = (A.HERE.parent / "synth.h").read_text()
        self.assertEqual(set(re.findall(r"\bg_sq\w+",source)),expected_names)
        for name,(typ,values) in parsed.items():
            self.assertEqual((typ,values),(A.TABLES[name][0],A.flatten(A.TABLES[name][1])))
            expected_size = 1536 if name in {"g_sqLead","g_sqSolo","g_sqHarm","g_sqBass","g_sqGtr","g_sqHold","g_sqDrum"} else 192 if name in {"g_sqRoot","g_sqType"} else 48
            self.assertEqual(len(values),expected_size)
            lo,hi = (-128,127) if typ=="signed char" else (0,255) if typ=="unsigned char" else (-32768,32767)
            self.assertTrue(all(lo<=v<=hi for v in values))


if __name__ == "__main__":
    unittest.main()
