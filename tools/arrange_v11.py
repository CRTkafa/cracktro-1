"""Bake 48 through-composed orders, without rendering or playback.

5000 samples/row at 44100 Hz: 174.149659864 seconds, unchanged.
Section gains are compositional estimates, NOT calibrated mastering results.
Run python tools/arrange_v11.py to regenerate song_data.h.
"""
from pathlib import Path
import motif as MO

HERE = Path(__file__).resolve().parent
ROWS, ORDERS, SPR, SRATE = 32, 48, 5000, 44100
X = -1
SECTIONS = [
    ("INTRO", 0, 1, -14), ("SYNTHWAVE", 2, 7, -14),
    ("METAL VERSE", 8, 11, -8), ("CHORUS", 12, 15, -6),
    ("SOLO", 16, 39, -10), ("ARRIVAL", 40, 45, -3), ("OUTRO", 46, 47, -14),
]
# Preserve synth.h's quiet-section ABI (IDs 0 and 10), not list indices.
SECTION_IDS = (0, 1, 4, 5, 8, 9, 10)
SOLO_PHASES = [
    ("spacious lead", 16, 19, -14), ("melodic guitar", 20, 24, -11),
    ("driving shredding", 25, 30, -9), ("organ counterpoint", 31, 35, -12),
    ("climactic burst", 36, 39, -6),
]
KEYCHANGE_ORDER, KEYCHANGE = 40, 2

# Four eight-row harmonic slots per order, in A natural minor degrees.
# Riffs use this global scale, not a new minor scale at each chord root.
PROGRESSION = [
    (0,0,4,4), (5,5,6,4),
    (0,0,5,5), (2,2,6,6), (3,3,0,0), (5,5,4,4), (2,2,3,3), (6,6,4,4),
    (0,0,6,4), (3,5,0,4), (5,6,3,4), (2,6,4,0),
    (0,5,2,6), (3,0,5,4), (5,2,6,3), (3,5,4,4),
    (0,0,5,5), (2,2,3,3), (5,5,6,6), (3,3,4,4),
    (0,5,2,6), (3,0,4,4), (5,2,3,6), (2,6,0,5), (3,5,4,0),
    (0,6,5,4), (3,0,2,4), (5,3,6,4), (2,5,0,6), (3,6,2,4), (5,6,4,0),
    (0,2,3,5), (6,5,3,2), (3,0,5,2), (5,3,2,6), (3,5,6,4),
    (0,3,5,6), (2,5,3,4), (5,6,0,4), (3,5,4,4),
    (0,0,0,0), (5,5,2,2), (3,3,6,6), (2,5,3,4), (5,6,3,4), (3,4,0,0),
    (5,3,0,0), (0,0,0,0),
]

def section_of(o):
    return next(i for i, (_, a, b, _) in enumerate(SECTIONS) if a <= o <= b)

def kit(kind):
    out = [0] * ROWS
    if kind == "syn":
        for r in range(0, ROWS, 4): out[r] = 1
        for r in (4,12,20,28): out[r] = 7  # kick + snare
        for r in range(2, ROWS, 4): out[r] = 3
    elif kind == "ride":
        for r in range(0, ROWS, 2): out[r] = 1 if r % 8 == 0 else 3
    elif kind == "half":
        for r in (0,16): out[r] = 1
        for r in (8,24): out[r] = 2
        for r in (6,14,22,30): out[r] = 3
    elif kind in ("metal", "drive"):
        for r in range(ROWS): out[r] = 3 if r % 2 == 0 else 0
        for r in (0,6,8,16,22,24): out[r] = 1
        if kind == "drive":
            for r in (1,3,10,17,19,26): out[r] = 1
        for r in (4,12,20,28): out[r] = 2
    return out

def order_spec(o):
    # Organ mode 2 and riff guitar never coincide. The melodic guitar is
    # g_sqSolo's existing guitar voice; no new voice or runtime API is needed.
    d = dict(owner="organ", kit=None, bass=0, org=2, syn=0, riff=False)
    if 2 <= o <= 7:
        d.update(owner="synth arp", kit="syn", bass=1, org=0, syn=1)
    elif 8 <= o <= 11:
        d.update(owner="riff", kit="metal", bass=2, org=0, riff=True)
    elif 12 <= o <= 15:
        d.update(owner="lead", kit="drive", bass=1, org=0)
    elif 16 <= o <= 19:
        d.update(owner="solo", kit="ride", bass=1, org=0)
    elif 20 <= o <= 24:
        d.update(owner="solo", kit="metal", bass=1, org=0)
    elif 25 <= o <= 30:
        d.update(owner="solo", kit="drive", bass=2, org=0)
    elif 31 <= o <= 35:
        # Organ owns the midrange; sparse solo answers above the voicings.
        d.update(owner="organ", kit="half", bass=1)
    elif 36 <= o <= 39:
        d.update(owner="solo", kit="drive", bass=2, org=0)
    elif 40 <= o <= 45:
        d.update(owner="solo", kit="metal" if o in (40,45) else "drive", bass=1, org=0)
    elif o == 46:
        d.update(kit="half", bass=1)
    return d

lead, solo, harm, bass, gtr = ([[X]*ROWS for _ in range(ORDERS)] for _ in range(5))
hold, drum = ([[0]*ROWS for _ in range(ORDERS)] for _ in range(2))
root, ctyp = ([[0]*4 for _ in range(ORDERS)] for _ in range(2))
arpo = [X]*ORDERS
orgm, rise, trim, syn, sect = ([0]*ORDERS for _ in range(5))
SOLO = {o: MO.extended_solo(o - 16) for o in range(16,40)}

for o in range(ORDERS):
    d, si = order_spec(o), section_of(o)
    sect[o], trim[o] = SECTION_IDS[si], SECTIONS[si][3]
    for _, a, b, t in SOLO_PHASES:
        if a <= o <= b: trim[o] = t
    orgm[o], syn[o] = d["org"], d["syn"]
    shift = KEYCHANGE if o >= KEYCHANGE_ORDER else 0
    for ci, degree in enumerate(PROGRESSION[o]):
        root[o][ci] = MO.deg(degree, 9 + shift) % 12
        ctyp[o][ci] = int(degree in (2,5,6))
    drum[o] = kit(d["kit"])
    if o in (2,8,12,20,25,36,40): drum[o][0] = 6  # kick + crash
    if o in (7,11,15,24,30,35,38,45):
        drum[o][28:32] = [2,0,2,4] if o % 2 else [2,1,2,2]
        if d["syn"]: drum[o][28] = 7  # fill preserves four-on-the-floor
    if 12 <= o <= 15: lead[o] = MO.lead_chorus(o - 12)
    if o in SOLO: solo[o] = list(SOLO[o])
    if 40 <= o <= 45:
        solo[o] = [n + shift if n >= 0 else X for n in MO.arrival_phrase(o - 40)]
    # Upper thirds punctuate two burst phrases, not a second continuous line.
    if o in (37,38):
        for r in (0,8,16,24):
            n = solo[o][r]
            if n >= 0: harm[o][r] = MO.scale_step(n, 2)
    if d["bass"]:
        rhythm = (0,4,8,12,16,20,24,28) if d["bass"] == 1 else (0,2,5,8,11,14,16,18,21,24,27,30)
        for r in rhythm:
            bass[o][r] = MO.deg(PROGRESSION[o][r // 8], 21 + shift)
    if d["riff"]:
        for r, degree in enumerate(MO.verse_riff(o - 8)):
            if degree is not None:
                gtr[o][r] = MO.deg(PROGRESSION[o][r // 8] + degree, 21)
                # The voice adds a fixed perfect fifth. B itself is in Am,
                # but B5 adds F#: return to this chord's root (E here).
                scale = {(9 + shift + n) % 12 for n in MO.MIN_IV}
                if (gtr[o][r] + 7) % 12 not in scale:
                    gtr[o][r] = MO.deg(PROGRESSION[o][r // 8], 21 + shift)
                bass[o][r] = MO.deg(PROGRESSION[o][r // 8], 21)
    if o == 39:
        # Twelve rows without triggers, then a four-note pickup. Envelopes
        # decay rather than hold: this does not promise digital silence.
        for lane, rest in ((solo,X),(bass,X),(drum,0)):
            lane[o][16:28] = [rest]*12
    if o == 47: trim[o] = -22

for o in (7,15,35,39): rise[o] = 1
gain = [round(1024 * 10 ** (t / 20)) for t in trim]
TABLES = {
    "g_sqLead": ("signed char", lead), "g_sqSolo": ("signed char", solo),
    "g_sqHarm": ("signed char", harm), "g_sqBass": ("signed char", bass),
    "g_sqGtr": ("signed char", gtr), "g_sqHold": ("unsigned char", hold),
    "g_sqDrum": ("unsigned char", drum), "g_sqRoot": ("signed char", root),
    "g_sqType": ("unsigned char", ctyp), "g_sqArpOct": ("signed char", arpo),
    "g_sqOrgMode": ("unsigned char", orgm), "g_sqRiser": ("unsigned char", rise),
    "g_sqGain": ("short", gain), "g_sqSyn": ("unsigned char", syn),
    "g_sqSect": ("unsigned char", sect),
}

def flatten(rows):
    return [v for row in rows for v in (row if isinstance(row,list) else [row])]

def header():
    out = "/* Through-composed form: 48 orders / 96 bars / 174.149659864 seconds.\n"
    out += "   Notes use MIDI-12; X=-1 means no trigger. No audio mastering validation.\n"
    out += "   Drum API: 6 = kick + crash; 7 = kick + snare (synthwave backbeats).\n"
    for i, (name,a,b,t) in enumerate(SECTIONS):
        out += f"   {name:12s} orders {a:2d}-{b:2d}; section ID {SECTION_IDS[i]}; proposed trim {t:+d} dB\n"
    for name,a,b,t in SOLO_PHASES:
        out += f"   SOLO {name:18s} orders {a}-{b}; proposed trim {t:+d} dB\n"
    out += "   Outro final order trim -22 dB. Generated by tools/arrange_v11.py. */\n"
    out += f"#define SNG_ORDERS {ORDERS}\n#define SNG_ROWS {ROWS}\n\n"
    for name,(ctype,rows) in TABLES.items():
        values = flatten(rows)
        out += f"static const {ctype} {name}[] = {{\n"
        for i in range(0,len(values),16):
            out += "    " + ",".join(map(str,values[i:i+16])) + ",\n"
        out += "};\n"
    return out

if __name__ == "__main__":
    (HERE.parent / "song_data.h").write_text(header(), encoding="utf-8")
    print(f"song_data.h: {ORDERS*ROWS} rows, {ORDERS*ROWS*SPR} samples, {ORDERS*ROWS*SPR/SRATE:.9f}s")
    for name,a,b,_ in SECTIONS:
        print(f"{name:12s} {a:02d}-{b:02d} {(b-a+1)*ROWS*SPR/SRATE:.3f}s")
    for name,a,b,_ in SOLO_PHASES:
        counts = [sum(n>=0 for n in solo[o]) for o in range(a,b+1)]
        print(f"SOLO {name}: {len(counts)} phrases; attacks {counts}")
