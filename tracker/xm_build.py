"""Native XM 1.04 export; all output is confined to this tracker directory.

No media is read and no song-length sample is created. The score is obtained
read-only from visualizer/score.py, which verifies the bake against the arranger.
Run with -B to suppress Python bytecode writes outside this directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import struct
import subprocess
import sys

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
FULL_TITLE = "CRTkafa @ cracktro 01"  # 21 bytes: cannot fit a native XM title.
TITLE = "CRTkafa cracktro 01"        # Native header; full text in instrument 14.
TRACKER = "CRTkafa XM Export"
OUTPUT = HERE / "CRTkafa-cracktro-01.xm"
CHANNELS, ROWS, ORDERS, SPEED = 32, 32, 48, 6
SAMPLE_RATE = 33452                  # XM C-4 rate 8363 * 4 (relative note +24)
PERIOD = 128
# +2/128 semitones brings 33452/128 within 0.304 cents of concert C4.
TUNE = 2
TRACKS = ("lead", "solo", "harmony", "bass", "guitar", "organ", "pad", "arp",
          "bell", "kick", "snare", "hat", "crash")
INSTRUMENT = {track: i+1 for i, track in enumerate(TRACKS)}
POOLS = {"lead": [0], "solo": [1], "harmony": [2], "bass": [3],
         "guitar": [4,5,6,7], "organ": [8,9,10],
         "pad": [11,12,13], "arp": [14,15,16], "bell": [17],
         "kick": [18], "snare": [19], "hat": [20], "crash": [21]}
# Native XM has no per-module preamp and note volume cannot exceed 64.
# Phase-coherent gain partners extend seven loud voices to 128 without adding
# new pitches, sample content, delays, plugins, or nonstandard format fields.
GAIN_PARTNERS = {"lead":22,"solo":23,"harmony":24,"bass":25,
                 "kick":26,"snare":27,"crash":28}
BASE_LEVELS = dict(zip(TRACKS, (30,42,28,38,24,16,15,24,24,56,44,24,32)))
LEVELS = {track: level*2.3 for track,level in BASE_LEVELS.items()}
PAN = {"lead": [100], "solo": [128], "harmony": [160], "bass": [128],
       "guitar": [36,220,36,220], "organ": [100,128,156],
       "pad": [36,128,220], "arp": [76,104,76], "bell": [76],
       "kick": [128], "snare": [124], "hat": [152], "crash": [164]}
# Native XM envelopes: (tick, volume), sustain-point index or None, fadeout.
# Non-sustained decay voices continue their envelope after score key-off.
ENVELOPES = {
    "lead": ([(0,64),(6,50),(12,35),(16,0)], 2, 0),
    "solo": ([(0,64),(1,56),(3,44),(6,30),(12,14),(18,7),(24,3),(36,0)], None, 0),
    "harmony": ([(0,64),(1,56),(3,44),(6,30),(12,14),(18,7),(24,3),(36,0)], None, 0),
    "bass": ([(0,32),(1,64),(8,45),(24,29),(30,0)], 3, 0),
    "guitar": ([(0,64),(6,29),(12,13),(18,6),(24,3),(36,0)], None, 0),
    "organ": ([(0,0),(1,64),(2,64),(7,0)], 2, 0),
    "pad": ([(0,0),(6,18),(14,36),(28,56),(44,64),(65,0)], 4, 0),
    "arp": ([(0,64),(3,42),(6,26),(12,11),(18,4),(28,0)], None, 0),
    "bell": ([(0,64),(255,64),(256,0)], None, 0),
    "kick": ([(0,64),(60,64),(61,0)], None, 0),
    "snare": ([(0,64),(60,64),(61,0)], None, 0),
    "hat": ([(0,64),(30,64),(31,0)], None, 0),
    "crash": ([(0,64),(120,64),(121,0)], None, 0),
}


def field(text, length):
    data = text.encode("ascii")
    if len(data) > length:
        raise ValueError(f"XM text exceeds {length} bytes: {text!r}")
    return data.ljust(length, b" ")


def load_source():
    # Child process isolates imports and disables all source-tree pyc writes.
    code = ("import sys,json;sys.path.insert(0,sys.argv[1]);"
            "from visualizer.score import build_score;print(json.dumps(build_score()))")
    proc = subprocess.run([sys.executable,"-I","-B","-c",code,str(ROOT)],
                          check=True, capture_output=True, text=True)
    score = json.loads(proc.stdout)
    source = (ROOT / "song_data.h").read_text(encoding="utf-8")
    match = re.search(r"g_sqGain\[\]\s*=\s*\{(.*?)\};", source, re.S)
    if not match:
        raise ValueError("Missing baked gain lane")
    gains = list(map(int,re.findall(r"-?\d+",match[1])))
    if len(gains) != ORDERS or score["bars"] != 96:
        raise ValueError("This export expects the current 48-order score")
    return score, gains


def timing(row_seconds, count=ROWS*ORDERS):
    """Error-diffuse adjacent integer BPMs; bound cumulative row-clock error."""
    bpm = SPEED * 2.5 / row_seconds
    low, high = math.floor(bpm), math.ceil(bpm)
    if low < 32 or high > 255:
        raise ValueError("Tempo is outside native Fxx BPM range")
    elapsed, bpms, starts = 0.0, [], [0.0]
    for row in range(count):
        chosen = min((low,high), key=lambda b: abs(elapsed+SPEED*2.5/b-(row+1)*row_seconds))
        elapsed += SPEED*2.5/chosen
        bpms.append(chosen)
        starts.append(elapsed)
    return bpms, starts


def row_index(seconds, row_seconds):
    value = seconds / row_seconds
    row = round(value)
    if abs(value-row) > 1e-7:
        raise ValueError("Off-row note requires explicit tick-effect support")
    return row


def make_patterns(score, gains):
    count = ROWS*ORDERS
    cells = np.zeros((count,CHANNELS,5), dtype=np.uint8)
    used_until = {channel: -1 for pool in POOLS.values() for channel in pool}
    cursor = {track: 0 for track in TRACKS}
    scheduled_offs = {}
    assigned = []
    events = [dict(n) for n in score["notes"]]
    # Percussion one-shots own a channel until the next strike; no fake notes
    # for a gated snare tail, ducking, or delay repetitions.
    events += [dict(n,pitch=60,end=None) for n in score["drums"]]
    events.sort(key=lambda n:(n["start"],n["track"],n["pitch"]))
    for note in events:
        track = note["track"]
        row = row_index(note["start"], score["row_seconds"])
        end = row_index(note["end"],score["row_seconds"]) if note["end"] is not None else row+1
        if not 0 <= row < end <= count:
            raise ValueError(f"Invalid note interval: {track}, {row}, {end}")
        pool = POOLS[track]
        choices = pool[cursor[track]:] + pool[:cursor[track]]
        free = [ch for ch in choices if used_until[ch] <= row]
        if not free:
            raise ValueError(f"Channel allocation would drop a {track} note at row {row}")
        channel = free[0]
        cursor[track] = (pool.index(channel)+1) % len(pool)
        # XM C-0 is note 1 and MIDI 12, so MIDI pitch -11 is the file note.
        pitch = note["pitch"] - 11
        if not 1 <= pitch <= 96:
            raise ValueError(f"Pitch outside XM's C-0..B-7: {note['pitch']}")
        total_volume = max(1,min(128 if track in GAIN_PARTNERS else 64,
                               round(LEVELS[track]*note["velocity"])))
        volume = (total_volume+1)//2 if track in GAIN_PARTNERS else total_volume
        cells[row,channel] = (pitch,INSTRUMENT[track],0x10+volume,8,PAN[track][pool.index(channel)])
        if track in GAIN_PARTNERS:
            partner = GAIN_PARTNERS[track]
            cells[row,partner] = cells[row,channel]
            cells[row,partner,2] = 0x10+total_volume//2
        used_until[channel] = end
        if note["end"] is not None and end < count:
            scheduled_offs[(end,channel)] = True
            if track in GAIN_PARTNERS:
                scheduled_offs[(end,GAIN_PARTNERS[track])] = True
        assigned.append(dict(track=track,pitch=note["pitch"],row=row,end=end,channel=channel))
    for (row,channel) in scheduled_offs:
        # A new strike on this very row supersedes key-off, as it does in the
        # source synth. Never allow an old note-off to overwrite a new note.
        if cells[row,channel,0] == 0:
            cells[row,channel,0] = 97
    bpms, starts = timing(score["row_seconds"])
    smoothed = 1.0
    for row in range(count):
        cells[row,31,3:] = (0x0F,bpms[row])
        want = gains[row//ROWS]/1024.0
        # Sample-domain section glide, represented at row centers as native
        # Gxx volume. No compressor/tape/reverb emulation is claimed.
        half = want + (smoothed-want)*(1-0.00006)**2500
        smoothed = want + (smoothed-want)*(1-0.00006)**5000
        t = (row+0.5)*score["row_seconds"]
        fade = min(1.0,t/3.0)**2
        if t > score["duration"]-1.8:
            f = max(0.0,(score["duration"]-t)/1.8)
            fade *= f*f*(3-2*f)
        global_volume = max(0,min(64,round(64*half/max(gains)*1024*fade)))
        cells[row,30,3:] = (0x10,global_volume)
    patterns = []
    for order in range(ORDERS):
        packed = bytearray()
        for cell in cells[order*ROWS:(order+1)*ROWS].reshape(-1,5):
            mask, values = 0x80, bytearray()
            for bit,value in enumerate(cell):
                if value:
                    mask |= 1 << bit
                    values.append(int(value))
            packed.append(mask)
            packed.extend(values)
        patterns.append(struct.pack("<IBHH",9,0,ROWS,len(packed))+packed)
    return patterns, assigned, starts


def saw(phase, harmonics=24):
    """Finite harmonic series: bounded-bandwidth saw at the sample base pitch."""
    out = np.zeros_like(phase)
    for harmonic in range(1,harmonics+1):
        out -= np.sin(2*np.pi*harmonic*phase)/harmonic
    return out * (2/np.pi)


def lowpass(values, coefficient):
    out = np.empty(len(values),dtype=np.float64)
    state = 0.0
    for i,value in enumerate(values):
        state += (value-state)*coefficient
        out[i] = state
    return out


def periodic_lowpass(values, coefficient, passes=12):
    """One-pole filter in periodic steady state, suitable for an XM loop."""
    values = np.asarray(values,dtype=np.float64)
    state = 0.0
    out = np.empty_like(values)
    for _ in range(passes):
        for i,value in enumerate(values):
            state += (value-state)*coefficient
            out[i] = state
    return out


def soft_clip(values):
    """The same no-CRT rational saturator used by the realtime C synth."""
    x = np.clip(np.asarray(values,dtype=np.float64),-3.0,3.0)
    return x*(27.0+x*x)/(27.0+9.0*x*x)


def pcm(values, loop=False):
    values = np.asarray(values,dtype=np.float64)
    values -= np.mean(values)
    peak = float(np.max(np.abs(values)))
    if not peak or not np.all(np.isfinite(values)):
        raise ValueError("Invalid synthesized sample")
    values *= 0.926/peak
    if not loop:
        # Tiny onset ramp, then a true zero endpoint for one-shots.
        attack = min(24,len(values)//8)
        release = min(int(SAMPLE_RATE*.02),len(values)//8)
        values[:attack] *= np.linspace(0,1,attack)
        values[-release:] *= np.linspace(1,0,release)
    return np.rint(values*32767).astype("<i2")


def melodic_sample(track):
    length = PERIOD if track in ("lead","bass") else PERIOD*256
    if track == "organ":
        length *= 2
    index = np.arange(length,dtype=np.float64)
    phase = index/PERIOD
    if track == "lead":
        # pulseWave() in synth.h is intentionally a raw 50% pulse. Retaining
        # its hard edge (rather than replacing it with an ideal Fourier square)
        # is part of the audible chip lead.
        values = np.where((phase % 1.0) < .5,1.0,-1.0)
    elif track in ("solo","harmony","guitar"):
        # Raw detuned saws -> fixed drive -> cabinet filter, in the same order
        # as the C path. One extra cycle closes the detuned loop exactly.
        a = (phase % 1.0)*2.0-1.0
        b = ((phase+index/length) % 1.0)*2.0-1.0
        raw = (a+b)*.5
        drive = {"solo":9.0,"harmony":8.0,"guitar":7.5}[track]
        values = periodic_lowpass(soft_clip(raw*drive),
                                  .66 if track=="solo" else (.60 if track=="harmony" else .52))
        if track == "guitar":
            body = periodic_lowpass(values,.019)
            values = values-body
    elif track == "bass":
        p = phase % 1.0
        raw = (p*2.0-1.0)*.65 + np.where(p < .5,.35,-.35)
        values = periodic_lowpass(raw,.22)
    elif track == "organ":
        values = np.zeros(length)
        for multiple,amp in zip((.5,1,1.5,2,3,4),(.62,1,.40,.58,.24,.30)):
            values += amp*.5*(np.sin(2*np.pi*phase*multiple)+
                                np.sin(2*np.pi*(phase*multiple+index/length)))
    elif track == "pad":
        det = (-3,-2,-1,0,1,2,3)
        bank = []
        for voice in det:
            p = (phase+voice*index/length) % 1.0
            duty = .5 + .18*math.sin(voice*.9)
            bank.append(.62*(p*2.0-1.0)+.38*np.where(p<duty,1.0,-1.0))
        values = sum(bank)/len(bank)
        # Keep the bed below the lead, as the resonant SVF does in voices.h.
        values = periodic_lowpass(periodic_lowpass(values,.18),.18)
        low = periodic_lowpass(values,.02)
        values -= low
    elif track == "arp":
        raw = sum((((phase+d*index/length+offset)%1.0)*2.0-1.0)
                  for d,offset in zip((-1,0,1),(0.0,1/3,2/3)))/3
        values = periodic_lowpass(raw,.34)
    else:
        raise ValueError(track)
    data = pcm(values,loop=True)
    return dict(name=track+" synth",pcm=data,loop_start=0,loop_length=len(data),
                relative=24,finetune=TUNE)


def one_shot(track, midi=60):
    rng = np.random.default_rng(0x435254+TRACKS.index(track))
    seconds = {"bell":4.0,"kick":.85,"snare":.65,"hat":.15,"crash":1.0}[track]
    length = round(seconds*SAMPLE_RATE)
    t = np.arange(length)/SAMPLE_RATE
    if track == "bell":
        hz = 440*2**((midi-69)/12)
        index = .35+(6.5*(.4+.6*.55)-.35)*np.exp(-t/.2)
        values = np.sin(2*np.pi*hz*t+index*np.sin(2*np.pi*hz*1.4*t))*np.exp(-t/1.6)
    elif track == "kick":
        tau = -1/(44100*math.log(.99955))
        phase = 46*t+(165-46)*tau*(1-np.exp(-t/tau))
        values = .55*np.sin(2*np.pi*phase)*np.exp(t*44100*math.log(.99988))
        values += rng.uniform(-1,1,length)*.22*np.exp(t*44100*math.log(.9955))
    elif track == "snare":
        noise = rng.uniform(-1,1,length)
        hp = noise-.6*lowpass(noise,.45)
        values = (.75*hp+.35*np.sin(2*np.pi*187*t))*np.exp(t*44100*math.log(.99977))
    else:
        noise = rng.uniform(-1,1,length)
        values = (noise-lowpass(noise,.70))*np.exp(t*44100*math.log(.9988 if track=="hat" else .99975))
    return dict(name=f"{track} {midi}" if track=="bell" else track+" synth",
                pcm=pcm(values),loop_start=0,loop_length=0,
                relative=24+60-midi,finetune=0)


def delta_encode(data):
    values = data.astype(np.int32)
    delta = np.diff(values,prepend=0)
    return ((delta+32768)%65536-32768).astype("<i2").tobytes()


def instrument_blob(track, samples, mapping=None):
    header = bytearray(263)
    struct.pack_into("<I22sBH",header,0,263,field(track,22),0,len(samples))
    struct.pack_into("<I",header,29,40)
    header[33:129] = bytes(mapping if mapping is not None else [0]*96)
    points,sustain,fadeout = ENVELOPES[track]
    for i,(tick,volume) in enumerate(points):
        struct.pack_into("<HH",header,129+i*4,tick,volume)
    header[225] = len(points)
    header[227] = sustain if sustain is not None else 0
    header[233] = 1 | (2 if sustain is not None else 0)
    struct.pack_into("<H",header,239,fadeout)
    sample_headers, sample_data = bytearray(), bytearray()
    for sample in samples:
        name = sample["name"]
        sample_headers.extend(struct.pack("<IIIBbBBbB22s",len(sample["pcm"])*2,
            sample["loop_start"]*2,sample["loop_length"]*2,64,sample["finetune"],
            0x10 | bool(sample["loop_length"]),128,sample["relative"],len(name),field(name,22)))
        sample_data.extend(delta_encode(sample["pcm"]))
    return bytes(header+sample_headers+sample_data)


def metadata_instrument(name):
    return struct.pack("<I22sBH",29,field(name,22),0,0)


def make_module(score, gains):
    patterns, assigned, starts = make_patterns(score,gains)
    instruments = []
    for track in TRACKS:
        if track == "bell":
            pitches = sorted({n["pitch"] for n in score["notes"] if n["track"]=="bell"})
            samples = [one_shot(track,pitch) for pitch in pitches]
            mapping = [min(range(len(pitches)),key=lambda i:abs(pitches[i]-(n+12))) for n in range(96)]
        else:
            samples = [one_shot(track) if track in ("kick","snare","hat","crash") else melodic_sample(track)]
            mapping = None
        instruments.append(instrument_blob(track,samples,mapping))
    instruments.append(metadata_instrument(FULL_TITLE))
    for section in score["sections"]:
        first = round(section["start"]/(ROWS*score["row_seconds"]))
        last = round(section["end"]/(ROWS*score["row_seconds"]))-1
        instruments.append(metadata_instrument(f"{section['name']} {first:02}-{last:02}"))
    header = bytearray(b"Extended Module: "+field(TITLE,20)+b"\x1a"+field(TRACKER,20))
    header.extend(struct.pack("<HI8H",0x0104,276,ORDERS,0,CHANNELS,ORDERS,len(instruments),1,SPEED,132))
    header.extend(bytes(range(ORDERS))+bytes(256-ORDERS))
    data = bytes(header)+b"".join(patterns)+b"".join(instruments)
    report = dict(title=TITLE,full_title=FULL_TITLE,channels=CHANNELS,orders=ORDERS,
                  rows_per_pattern=ROWS,instruments=len(instruments),
                  score_notes=len(score["notes"]),score_drums=len(score["drums"]),
                  native_note_on_events=len(assigned)+sum(n["track"] in GAIN_PARTNERS for n in assigned),
                  gain_partner_channels=GAIN_PARTNERS,
                  source_duration_seconds=score["duration"],xm_tempo_duration_seconds=starts[-1],
                  max_row_clock_error_ms=max(abs(s-i*score["row_seconds"]) for i,s in enumerate(starts))*1000,
                  sections=score["sections"],bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    return data, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output",type=Path,default=OUTPUT)
    args = parser.parse_args()
    output = args.output.resolve()
    if not output.is_relative_to(HERE) or output.suffix.lower() != ".xm":
        parser.error("Output must be an .xm file inside tracker/")
    data,report = make_module(*load_source())
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_bytes(data)
    (HERE/"build_report.json").write_text(json.dumps(report,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(report,indent=2))


if __name__ == "__main__":
    main()
