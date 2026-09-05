"""Written phrases for the 48-order form, in MIDI-minus-12 note numbers.

The call A-F-E remains in the chorus. The solo also develops the natural
minor run and pedal contour of music_render.py V7_SOLO (used by v8), with
new intervallic runs, lyrical lines, displaced accents and upper responses.
No register folding or clipping: pitches are chosen in the score itself.
Each phrase is exactly one 32-row / two-bar order, not a looping cell.
"""
ROWS, X, A4 = 32, -1, 57
MIN_IV = (0,2,3,5,7,8,10)

def deg(d, base=A4):
    octave, index = divmod(d,7)
    return base + 12*octave + MIN_IV[index]

def scale_step(note, steps):
    octave, pc = divmod(note-A4,12)
    return deg(octave*7 + MIN_IV.index(pc) + steps)

def lay(pitches, rhythm=None, base=A4):
    """Place explicit attacks; X is no trigger, not sustain or note-off.

    Repeated pitches in lyrical passages deliberately refresh the existing
    decaying solo envelope. No claim of continuous legato is made.
    """
    if rhythm is None: rhythm = range(len(pitches))
    assert len(pitches) == len(rhythm), "pitch/rhythm length mismatch"
    assert len(set(rhythm)) == len(rhythm), "two attacks in one lane/row"
    out = [X]*ROWS
    for p,r in zip(pitches,rhythm):
        assert 0 <= r < ROWS
        if p is not None:
            out[r] = deg(p,base)
            assert 0 <= out[r] <= 127, "signed-char note overflow"
    return out

def lead_chorus(i):
    # Four distinct statements in the sole chorus; no octave folding.
    phrases = (
        ((0,5,4,4,2,3,4,6,5,4), (0,4,6,8,12,16,18,20,24,26)),
        ((2,4,7,6,4,2,0,2,3,4,4), (0,2,4,7,10,12,16,18,20,24,26)),
        ((5,7,9,7,6,4,2,3,5,4), (0,3,6,8,11,14,16,20,24,26)),
        ((3,5,4,2,1,0,-1,1,4,4), (0,2,6,10,12,16,18,20,24,26)),
    )
    pitches, rhythm = phrases[i]
    return lay(pitches,rhythm,base=A4)

# Each tuple is (scale degrees, attack rows, base). Dense lines are written
# in full, including rests, so there is no repeated motif-call generator.
SOLO_SCORE = (
    # 16-19: spacious pickup, displaced answer, longer arcs entering the band.
    ((0,5,4,4,2,3,1), (0,6,10,12,18,22,27), 45),
    ((2,4,6,5,3,2,0,1), (1,5,9,12,17,21,24,28), 57),
    ((5,4,2,0,2,3,6,4,3), (0,3,7,10,16,19,22,25,28), 57),
    ((3,4,6,7,7,5,4,2,1,4), (0,4,7,10,12,16,20,24,27,29), 57),
    # 20-24: lyrical electric guitar; repeated tones refresh long gestures,
    # with short sixteenth flourishes embedded between them.
    ((0,2,4,7,7,7,6,5,4,2,3,5,4,4),
     (0,2,4,6,8,10,13,14,15,18,20,22,25,27), 57),
    ((3,5,7,9,8,7,5,4,2,0,2,4,4,4,3,1),
     (0,2,4,6,7,8,10,12,14,16,18,20,22,24,27,29), 57),
    ((5,5,7,9,10,9,7,6,4,2,3,5,7,6,4,4,2),
     (0,2,5,6,7,8,10,12,14,16,18,20,22,23,24,26,29), 57),
    ((2,4,6,7,9,7,4,2,0,2,4,6,5,3,2,0,0,1),
     (0,1,2,4,6,8,10,12,14,16,17,18,20,22,24,26,28,30), 57),
    ((3,4,5,7,9,10,9,7,5,3,2,4,6,7,6,4,2,1,0,0),
     (0,1,2,3,4,6,8,10,12,14,16,17,18,19,20,22,24,26,28,30), 57),
    # 25: v8 natural-minor ascent/descent + broken arpeggio contour retained.
    ((0,1,2,3,4,5,6,7, 6,5,4,3,2,1,0,-1,
      0,2,4,7,9,7,4,2, 0,1,2,4,7,6,4,0), None, 57),
    # 26: contrary thirds, a falling sixth, then upward displaced groups.
    ((3,5,4,6,5,7,6,9, 7,5,3,2,0,2,4,6,
      2,4,6,7,4,6,7,9, 6,7,9,10,9,7,4,None), None, 57),
    # 27: v8's pedal-point gesture, natural seventh against the shared scale.
    ((7,4,7,5,7,4,7,3, 7,4,7,2,7,4,7,1,
      7,4,7,6,7,4,7,5, 7,4,7,4,7,6,7,8), None, 57),
    # 28: cross-string arpeggios and a long cascading answer.
    ((2,6,9,11,9,6,2,4, 5,9,12,9,5,3,0,3,
      7,9,7,6,5,4,3,2, 1,0,-1,1,2,4,6,None), None, 57),
    # 29: low-to-high sixteenth sequence with changing group lengths.
    ((3,2,0,-1,0,2,3,5, 6,3,5,6,7,5,6,7,
      9,6,7,9,10,9,7,5, 4,2,1,2,4,6,7,None), None, 57),
    # 30: descending sixths become a rising scalar exit; two-row breath.
    ((5,0,6,1,7,2,9,4, 10,5,9,4,7,2,6,1,
      4,5,6,7,9,10,12,10, 9,7,6,4,2,0,None,None), None, 57),
    # 31-35: upper answers over moving organ chords; guitar riff is absent.
    ((0,2,4,2,3,5,3,2), (2,4,6,11,14,18,22,27), 69),
    ((6,4,4,3,1,0,2,4,2), (1,4,6,10,14,18,22,25,28), 69),
    ((3,5,7,5,4,2,0,2,4,6), (2,5,8,11,14,18,21,24,27,29), 69),
    ((5,4,2,3,5,3,1,0,2,4,6,4), (1,3,5,9,12,15,18,21,24,26,28,30), 69),
    ((3,3,5,6,5,3,2,0,2,4,6,4,3,1), (0,2,5,7,9,11,14,17,20,22,24,26,28,30), 69),
    # 36-38: continuous sixteenths, large interval shapes and a higher peak.
    ((0,4,7,9,7,4,2,5, 3,5,7,10,9,7,5,3,
      5,7,9,12,10,9,7,5, 6,7,9,10,12,10,9,7), None, 57),
    ((9,7,5,2,5,7,9,12, 10,9,7,5,3,5,7,10,
      7,6,4,2,4,6,7,11, 9,7,6,4,2,4,6,7), None, 57),
    ((12,7,11,7,10,6,9,5, 7,9,10,12,14,12,10,9,
      7,5,6,7,9,10,12,14, 12,10,9,7,6,4,2,1), None, 57),
    # 39: dense first bar, twelve trigger-free rows, four-note rising pickup.
    ((3,5,7,10,9,7,5,3,5,7,9,12,10,7,4,4,4,6,7,9),
     tuple(range(16)) + (28,29,30,31), 57),
)

def extended_solo(i):
    pitches, rhythm, base = SOLO_SCORE[i]
    return lay(pitches, rhythm, base)

def arrival_phrase(i):
    # Six new phrases after the +2 shift, not a repeated chorus. A high
    # tonic is refreshed, answered, expanded, and finally brought home.
    phrases = (
        ((14,14,14,12,11,9,7,7), (0,2,4,10,14,18,24,26)),
        ((5,7,9,12,12,10,9,7,6,4,2,2), (0,2,4,6,8,12,14,16,20,22,26,28)),
        ((3,5,7,10,9,7,6,5,3,4,6,7,7), (0,3,6,8,10,12,15,18,21,24,26,28,30)),
        ((2,4,6,9,7,6,5,7,9,12,10,9,7,5,4,4), tuple(range(0,32,2))),
        ((5,7,9,10,12,10,9,7,6,4,3,5,7,6,4,2,1,0),
         (0,1,2,3,4,6,8,10,12,14,16,18,20,22,24,26,28,30)),
        ((3,5,4,2,1,4,7,7,4,2,0,0), (0,2,4,6,8,10,12,14,18,22,26,28)),
    )
    return lay(*phrases[i])

def verse_riff(i):
    # Four individually paced two-bar riffs. Chord-relative root/fifth/octave
    # degrees preserve both key consonance and the guitar's power fifth.
    phrases = (
        ((0,0,4,0,7,4,0,0,4,7,4,0,4,0,0), (0,2,3,6,8,10,12,15,16,18,21,24,26,28,30)),
        ((0,4,0,7,4,0,0,4,0,7,4,0,0,4,7,0), (0,1,4,6,8,11,12,14,16,19,20,22,24,27,28,31)),
        ((0,0,7,4,0,4,7,0,4,0,7,4,0,0,4,0,7), (0,2,4,5,8,10,12,14,16,18,20,22,24,25,28,30,31)),
        ((0,4,7,4,0,0,4,0,7,4,0,4,7,4,0,0,4,0), (0,1,2,4,6,8,10,12,14,16,18,20,22,24,26,28,29,30)),
    )
    out = [None]*ROWS
    for p,r in zip(*phrases[i]): out[r] = p
    return out
