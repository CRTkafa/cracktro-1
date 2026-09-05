"""Read-only piano-roll score for CRTkafa @ cracktro 01.

build_score() verifies every baked table against arrange_v11 before extracting
events from song_data.h. It does not render, inspect, or modify media. The video
renderer must stream-copy CRTkafa.mp4 audio separately; this score cannot prove
that an arbitrary encoded video was produced from these source files.

Times use the engine's sample clock; pitches are conventional MIDI (engine+12).
Durations are visual notation: lead/bass stop at their 2/4-row rest gates or
next strike; solo/harmony at at most 4 rows; guitar at 3 rows (8 when held);
bell at 16 rows; polysynth arp at 2 rows. Bass also ends at a voice handoff.
Release, delay, reverb, crossfade, and FM-sideband tails are not extra notes.
Organ/pad chords merge only while the complete engine voicing stays unchanged.
Guitar shows root and the deliberately played fifth, not detuned duplicates;
organ shows its three chord tones, not drawbar partials. Velocity is trigger
strength, not measured loudness, section gain, or master fade automation.

The legacy chip arp (unused in 01) is shown as tick-length pitch segments, not
as invented note-on attacks. There is no EP trigger in songTick, so no EP notes.
No file writes occur on import or in build_score(). Only the CLI prints JSON.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
TRACKS = frozenset(("lead", "solo", "harmony", "bass", "guitar", "organ",
                    "pad", "arp", "bell"))
DRUM_TRACKS = frozenset(("kick", "snare", "hat", "crash"))


def _defines(source):
    """Simple literal/object aliases only; do not evaluate arbitrary C/Python."""
    return dict(re.findall(r"^#define\s+(\w+)\s+([\w.+-]+)", source, re.M))


def _number(defines, name):
    value = defines[name]
    seen = {name}
    while value in defines:
        if value in seen:
            raise ValueError(f"Cyclic macro: {name}")
        seen.add(value)
        value = defines[value]
    return float(value.rstrip("fF"))


def _arrangement():
    # Isolate the arranger's sibling import of motif without modifying sys.path
    # or sys.modules in the renderer. -B prevents even bytecode-cache writes.
    code = ("import sys,json; sys.path.insert(0,sys.argv[1]); import arrange_v11 as a; "
            "print(json.dumps(dict(tables={k:[t,a.flatten(v)] for k,(t,v) in "
            "a.TABLES.items()},sections=a.SECTIONS,section_ids=a.SECTION_IDS,"
            "orders=a.ORDERS,rows=a.ROWS,spr=a.SPR,srate=a.SRATE)))")
    result = subprocess.run([sys.executable, "-I", "-B", "-c", code,
                             str(ROOT / "tools")], check=True,
                            capture_output=True, text=True)
    return json.loads(result.stdout)


def _inputs():
    source = (ROOT / "song_data.h").read_text(encoding="utf-8")
    tables = {}
    for typ, name, body in re.findall(
            r"static const (signed char|unsigned char|short) (g_sq\w+)\[\]"
            r"\s*=\s*\{(.*?)\};", source, re.S):
        if name in tables:
            raise ValueError(f"Duplicate table: {name}")
        tables[name] = [typ, list(map(int, re.findall(r"-?\d+", body)))]
    arrangement = _arrangement()
    if tables != arrangement["tables"]:
        raise ValueError("song_data.h differs from arrange_v11; refusing a stale score")
    synth = (ROOT / "synth.h").read_text(encoding="utf-8")
    voices = (ROOT / "voices.h").read_text(encoding="utf-8")
    defines = _defines(source + "\n" + synth + "\n" + voices)
    for macro, key in (("SNG_ORDERS", "orders"), ("SNG_ROWS", "rows"),
                       ("SPR", "spr"), ("SRATE", "srate")):
        if _number(defines, macro) != arrangement[key]:
            raise ValueError(f"Clock mismatch: {macro}")
    if arrangement["rows"] != 32 or int(_number(defines, "TPR")) != 6:
        raise ValueError("Extractor expects the current 32-row/six-tick engine")
    return {key: value[1] for key, value in tables.items()}, arrangement, defines


def _extract(t, arrangement, defines):
    rows, orders = arrangement["rows"], arrangement["orders"]
    spr, rate = arrangement["spr"], arrangement["srate"]
    row_seconds = spr / rate
    count, duration = rows * orders, rows * orders * spr / rate
    notes, drums, sections = [], [], []

    def add(track, pitch, start_row, end_row, velocity=1.0):
        notes.append(dict(track=track, pitch=int(pitch) + 12,
                          start=start_row * spr / rate,
                          end=min(end_row * spr / rate, duration),
                          velocity=float(velocity)))

    def strikes(track, lane, length, pitches=lambda n, k: (n,), condition=None):
        events = [(k, n) for k, n in enumerate(t[lane])
                  if n >= 0 and (condition is None or condition(k))]
        for i, (k, n) in enumerate(events):
            end = min(count, k + (length(k) if callable(length) else length))
            if i + 1 < len(events):
                end = min(end, events[i+1][0])
            if track == "bass":
                for boundary in range((k//rows + 1)*rows, end, rows):
                    if bool(t["g_sqSyn"][boundary//rows]) != bool(t["g_sqSyn"][k//rows]):
                        end = boundary
                        break
            for pitch in pitches(n, k):
                add(track, pitch, k, end)

    def bass_pitch(note, k):
        if t["g_sqSyn"][k//rows]:
            hz = 440.0 * 2 ** ((note - 57) / 12)
            while hz > _number(defines, "PB_FOLD_HI"):
                hz /= 2
                note -= 12
            while hz < _number(defines, "PB_FOLD_LO"):
                hz *= 2
                note += 12
        return (note,)

    strikes("lead", "g_sqLead", 2)
    strikes("solo", "g_sqSolo", 4)
    strikes("harmony", "g_sqHarm", 4,
            condition=lambda k: t["g_sqSolo"][k] >= 0)
    strikes("bass", "g_sqBass", 4, pitches=bass_pitch)
    strikes("guitar", "g_sqGtr", lambda k: 8 if t["g_sqHold"][k] else 3,
            pitches=lambda n, k: (n, n+7))

    # Stateful voices: compare the full ordered voicing, as orgSet/padSet do.
    active = {track: (None, 0) for track in ("organ", "pad")}
    for k in range(count + 1):
        chord = {"organ": None, "pad": None}
        if k < count:
            o, r = divmod(k, rows)
            root = t["g_sqRoot"][o*4 + r//8]
            major = bool(t["g_sqType"][o*4 + r//8])
            offsets = (0, 4 if major else 3, 7)
            mode = t["g_sqOrgMode"][o]
            if mode:
                base = 24 + (12 if mode == 2 else 0) + root
                chord["organ"] = (mode, tuple(base+n for n in
                                              ((0, 7, 12) if mode == 1 else offsets)))
            if t["g_sqSyn"][o]:
                base = int(_number(defines, "PAD_BASE"))
                chord["pad"] = (1, tuple(base + (root+n) % 12 for n in offsets))
        for track in active:
            previous, start = active[track]
            if chord[track] != previous:
                if previous is not None:
                    for pitch in previous[1]:
                        add(track, pitch, start, k)
                active[track] = (chord[track], k)

    drum_map = {0: (), 1: (("kick", 1.0),), 2: (("snare", .85),),
                3: (("hat", .30),), 4: (("hat", .55),),
                5: (("crash", .95),),
                6: (("kick", 1.0), ("crash", .95)),
                7: (("kick", 1.0), ("snare", .85))}
    ticks = int(_number(defines, "TPR"))
    for k in range(count):
        o, r = divmod(k, rows)
        root = t["g_sqRoot"][o*4 + r//8]
        major = bool(t["g_sqType"][o*4 + r//8])
        for track, velocity in drum_map[t["g_sqDrum"][k]]:
            drums.append(dict(track=track, start=k * spr / rate, velocity=velocity))
        if r == 0 and t["g_sqSect"][o] in (0, 7, 10) and o % 2 == 0:
            note = 48 + root
            while note < _number(defines, "BELL_LO"):
                note += 12
            while note > _number(defines, "BELL_HI"):
                note -= 12
            add("bell", note, k, min(k+16, count), .55)
        if t["g_sqSyn"][o] and r % 2 == 0:
            offsets = (0, 4 if major else 3, 7, 12)
            add("arp", 36 + root + offsets[(r//2) & 3], k, k+2,
                1.0 if r % 8 == 0 else .62)
        if t["g_sqArpOct"][o] >= 0:
            offsets = (0, 4 if major else 3, 7)
            for tick in range(ticks):
                # Integer tick boundaries match TICKLEN; SPR/TPR truncation
                # must not accumulate across rows. These are pitch segments.
                begin = k*spr + tick*spr//ticks
                end = k*spr + (tick+1)*spr//ticks
                pitch = t["g_sqArpOct"][o] + root + offsets[(tick+r*ticks) % 3]
                notes.append(dict(track="arp", pitch=pitch+12, start=begin/rate,
                                  end=end/rate, velocity=1.0))

    for (name, first, last, _), section_id in zip(arrangement["sections"],
                                                arrangement["section_ids"]):
        if t["g_sqSect"][first:last+1] != [section_id] * (last-first+1):
            raise ValueError(f"Section metadata mismatch: {name}")
        sections.append(dict(name=name, start=first*rows*spr/rate,
                             end=(last+1)*rows*spr/rate))
    notes.sort(key=lambda event: (event["start"], event["track"], event["pitch"], event["end"]))
    drums.sort(key=lambda event: (event["start"], event["track"]))
    sections.sort(key=lambda event: event["start"])
    score = dict(duration=duration, notes=notes, drums=drums, sections=sections,
                 row_seconds=row_seconds, bars=count//16)
    _validate(score)
    return score


def _validate(score):
    for event in score["notes"] + score["drums"]:
        if not (math.isfinite(event["start"]) and 0 <= event["start"] < score["duration"]
                and math.isfinite(event["velocity"]) and 0 <= event["velocity"] <= 1):
            raise ValueError(f"Invalid event: {event}")
        if "pitch" in event:
            if not (event["track"] in TRACKS and isinstance(event["pitch"], int)
                    and 0 <= event["pitch"] <= 127 and math.isfinite(event["end"])
                    and event["start"] < event["end"] <= score["duration"]):
                raise ValueError(f"Invalid note: {event}")
        elif event["track"] not in DRUM_TRACKS:
            raise ValueError(f"Invalid drum: {event}")
    end = 0.0
    for section in score["sections"]:
        if section["start"] != end or not section["start"] < section["end"]:
            raise ValueError("Sections must cover the score without gaps or overlaps")
        end = section["end"]
    if end != score["duration"]:
        raise ValueError("Sections do not cover the song duration")


def build_score() -> dict:
    """Return sorted notes/drums/sections; refuse an outdated or invalid bake."""
    return _extract(*_inputs())


if __name__ == "__main__":
    print(json.dumps(build_score(), separators=(",", ":"), allow_nan=False))
