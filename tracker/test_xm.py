"""Structural, score-equivalence, synthesis and independent-decoder checks.

python -B -m unittest discover -s tracker -p test_xm.py -v
"""
from collections import Counter
import hashlib
import math
from pathlib import Path
import shutil
import struct
import subprocess
import unittest

import numpy as np

if __package__:
    from . import xm_build as B, xm_verify as V
else:
    import xm_build as B
    import xm_verify as V


class XmTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.data = B.OUTPUT.read_bytes()
        cls.parsed = V.parse_xm(cls.data)
        cls.score,cls.gains = B.load_source()

    def test_native_header_title_and_metadata_limit(self):
        p = self.parsed
        self.assertEqual(p["title"],"CRTkafa cracktro 01")
        self.assertEqual(len(B.FULL_TITLE.encode("ascii")),21)
        with self.assertRaisesRegex(ValueError,"exceeds 20"):
            B.field(B.FULL_TITLE,20)
        self.assertEqual(p["instruments"][13]["name"],"CRTkafa @ cracktro 01")
        self.assertEqual(p["tracker"],"CRTkafa XM Export")
        self.assertEqual(p["channels"],32)
        self.assertEqual(p["orders"],list(range(48)))
        self.assertEqual([len(pattern) for pattern in p["patterns"]],[32]*48)
        self.assertEqual(p["speed"],6)
        self.assertEqual(p["bpm"],132)
        self.assertEqual([i["name"] for i in p["instruments"][:13]],list(B.TRACKS))
        self.assertTrue(all(not i["samples"] for i in p["instruments"][13:]))

    def test_all_score_notes_and_hits_survive_without_new_attacks(self):
        actual = Counter()
        for order in self.parsed["orders"]:
            for row,cells in enumerate(self.parsed["patterns"][order]):
                for channel,(note,ins,vol,effect,param) in enumerate(cells):
                    if channel in B.GAIN_PARTNERS.values():
                        continue
                    if 1 <= note <= 96:
                        track = self.parsed["instruments"][int(ins)-1]["name"]
                        actual[(order*32+row,track,int(note)+11)] += 1
        expected = Counter((round(n["start"]/self.score["row_seconds"]),n["track"],n["pitch"])
                           for n in self.score["notes"])
        expected.update((round(n["start"]/self.score["row_seconds"]),n["track"],60)
                        for n in self.score["drums"])
        self.assertEqual(actual,expected)
        self.assertEqual(sum(actual.values()),1398+779)
        self.assertEqual(self.parsed["note_count"],3750)
        self.assertEqual(self.parsed["distinct_instrument_note_onsets"],2177)

    def test_gain_partners_preserve_notes_pan_envelopes_and_valid_volume(self):
        cells = np.concatenate(self.parsed["patterns"])
        for track,partner in B.GAIN_PARTNERS.items():
            primary = B.POOLS[track][0]
            np.testing.assert_array_equal(cells[:,primary,[0,1,3,4]],cells[:,partner,[0,1,3,4]])
            for row in range(1536):
                if cells[row,primary,0] in range(1,97):
                    a,b = map(int,(cells[row,primary,2],cells[row,partner,2]))
                    self.assertTrue(0x10 <= a <= 0x50 and 0x10 <= b <= 0x50)
                    self.assertLessEqual(abs(a-b),1)

    def test_no_keyoff_overwrites_restrike_and_gates_have_channels(self):
        _,assigned,_ = B.make_patterns(self.score,self.gains)
        cells = np.concatenate(self.parsed["patterns"])
        notes = {(n["row"],n["channel"]) for n in assigned}
        for event in assigned:
            row,end,channel = event["row"],event["end"],event["channel"]
            self.assertIn(channel,B.POOLS[event["track"]])
            self.assertEqual(int(cells[row,channel,0]),event["pitch"]-11)
            if event["track"] not in ("kick","snare","hat","crash") and end < 1536:
                if (end,channel) not in notes:
                    self.assertEqual(int(cells[end,channel,0]),97)
        self.assertEqual(len(notes),2177)

    def test_timing_section_positions_and_effects(self):
        p = self.parsed
        errors = [abs(t-i*self.score["row_seconds"]) for i,t in enumerate(p["row_times"])]
        self.assertLess(max(errors),.00043)
        self.assertLess(abs(p["duration_seconds"]-self.score["duration"]),.0003)
        self.assertEqual(len(p["row_times"]),1537)
        cells = np.concatenate(p["patterns"])
        self.assertEqual(set(map(int,cells[:,31,4])),{132,133})
        self.assertTrue(np.all(cells[:,31,3] == 0x0F))
        self.assertTrue(np.all(cells[:,30,3] == 0x10))
        self.assertEqual(cells[-1,30,4],0)
        for index,section in enumerate(self.score["sections"]):
            first = round(section["start"]/(32*self.score["row_seconds"]))
            last = round(section["end"]/(32*self.score["row_seconds"]))-1
            self.assertEqual(p["instruments"][14+index]["name"],f"{section['name']} {first:02}-{last:02}")
            self.assertLess(abs(p["row_times"][first*32]-section["start"]),.00043)

    def test_sample_delta_decode_loops_and_synthesis_are_real(self):
        samples = [s for i in self.parsed["instruments"] for s in i["samples"]]
        self.assertEqual(len(samples),14)
        hashes = set()
        for sample in samples:
            data = sample["pcm"]
            self.assertEqual(len(data)*2,sample["bytes"])
            self.assertLessEqual(len(data),B.SAMPLE_RATE*4)
            self.assertGreater(np.std(data.astype(float)),10)
            self.assertLess(np.max(np.abs(data.astype(np.int32))),30500)
            self.assertLess(abs(np.mean(data)),20)
            hashes.add(hashlib.sha256(data.tobytes()).hexdigest())
            if sample["loop_length"]:
                a = sample["loop_start"]
                end = a+sample["loop_length"]
                self.assertLessEqual(end,len(data))
                # A loop seam must be no worse than an ordinary sample step.
                self.assertLessEqual(abs(int(data[a])-int(data[end-1])),
                                     int(np.max(np.abs(np.diff(data.astype(np.int32)))))+2)
            else:
                self.assertEqual(int(data[0]),0)
                self.assertEqual(int(data[-1]),0)
        self.assertEqual(len(hashes),14)
        original = np.array([0,32767,-32768,-1,15000,-20000,0],dtype=np.int16)
        encoded = np.frombuffer(B.delta_encode(original),dtype="<i2")
        decoded = ((np.cumsum(encoded,dtype=np.int64)+32768)%65536-32768).astype(np.int16)
        np.testing.assert_array_equal(decoded,original)

    def test_pitch_tuning_and_bell_multisample_duration(self):
        for index in range(8):
            sample = self.parsed["instruments"][index]["samples"][0]
            readerate = 8363*2**((sample["relative"]+sample["finetune"]/128)/12)
            pitch = readerate/128
            error_cents = 1200*math.log2(pitch/(440*2**(-9/12)))
            self.assertLess(abs(error_cents),.304)
        bell = self.parsed["instruments"][8]
        for midi in (79,81):
            sample = bell["samples"][bell["mapping"][midi-12]]
            readerate = 8363*2**((midi-12+sample["relative"]-48)/12)
            self.assertEqual(readerate,33452)
            self.assertAlmostEqual(len(sample["pcm"])/readerate,4.0)

    def test_parser_rejects_truncation_bad_orders_and_stereo_extensions(self):
        for data in (self.data[:80],self.data[:-1]):
            with self.assertRaises(ValueError):
                V.parse_xm(data)
        bad = bytearray(self.data)
        bad[80] = 250
        with self.assertRaisesRegex(ValueError,"order reference"):
            V.parse_xm(bad)
        first_instrument = 336
        for _ in range(48):
            header,_,_,size = struct.unpack_from("<IBHH",self.data,first_instrument)
            first_instrument += header+size
        bad = bytearray(self.data)
        bad[first_instrument+263+14] |= 0x20
        with self.assertRaisesRegex(ValueError,"native mono"):
            V.parse_xm(bad)
        bad = bytearray(self.data)
        struct.pack_into("<I",bad,first_instrument+263+8,0xFFFFFFFE)
        with self.assertRaisesRegex(ValueError,"loop extent"):
            V.parse_xm(bad)

    def test_rebuild_is_identical_and_sources_remain_unchanged(self):
        paths = [B.ROOT/name for name in ("song_data.h","synth.h","voices.h",
                                         "visualizer/score.py","tools/arrange_v11.py")]
        before = {p:(p.stat().st_mtime_ns,hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths}
        regenerated,_ = B.make_module(*B.load_source())
        self.assertEqual(regenerated,self.data)
        after = {p:(p.stat().st_mtime_ns,hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths}
        self.assertEqual(before,after)


@unittest.skipUnless(shutil.which("ffmpeg"),"FFmpeg unavailable; structural checks still run")
class DecoderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        demuxers = subprocess.run(["ffmpeg","-hide_banner","-demuxers"],
                                  capture_output=True,text=True,check=True)
        if "libopenmpt" not in demuxers.stdout:
            raise unittest.SkipTest("FFmpeg was built without libopenmpt")
        cls.data = B.OUTPUT.read_bytes()

    def test_full_decode_is_non_silent_finite_unclipped_and_correct_length(self):
        report = V.summary(self.data,decoded=True)
        decode = report["decode"]
        self.assertEqual(decode["full_scale_samples"],0)
        self.assertLess(abs(decode["seconds"]-report["duration_seconds"]),.15)
        self.assertTrue(-20 <= decode["rms_dbfs"] <= -17)
        self.assertTrue(-3 <= decode["peak_dbfs"] <= -1)
        self.assertTrue(all(value > -60 for value in decode["order_rms_dbfs"]))

    def test_decoder_concert_pitch_440hz_not_an_octave_off(self):
        # Replace only pattern 0 in memory with a sustained A4 lead, unity
        # global volume, and 132 BPM. The sample itself is the delivered one.
        cells = np.zeros((32,32,5),dtype=np.uint8)
        cells[0,0] = (69-11,1,0x50,8,128)
        cells[0,30,3:] = (0x10,64)
        cells[0,31,3:] = (0x0F,132)
        pattern = struct.pack("<IBHH",9,0,32,cells.size)+cells.tobytes()
        _,_,_,old_size = struct.unpack_from("<IBHH",self.data,336)
        data = self.data[:336]+pattern+self.data[336+9+old_size:]
        pcm = V.decode_pcm(data,1.0)
        signal = pcm[11025:41895].mean(axis=1)
        fft = np.abs(np.fft.rfft(signal*np.hanning(len(signal)),n=262144))
        frequency = np.fft.rfftfreq(262144,1/44100)[np.argmax(fft)]
        self.assertLess(abs(frequency-440),.5)


if __name__ == "__main__":
    unittest.main()
