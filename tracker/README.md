# CRTkafa @ cracktro 01 — native XM

`CRTkafa-cracktro-01.xm` is a native FastTracker II XM 1.04 arrangement, with
32 channels, 48 orders, and 48 distinct 32-row patterns. It preserves all
1,398 pitched score events and 779 drum hits, including the long solo and
the seven section boundaries. It contains 13 playable instruments and 14
individually synthesized mono samples, not a recorded full-song sample.

## Build and verify

Requirements: Python 3.10 or later, NumPy, and the existing adjacent score/source
files. FFmpeg with its `libopenmpt` demuxer is needed for decode verification.
The tools do not install dependencies, open windows, or play audio.

Run from the `cracktro` directory:

```powershell
python -B tracker/xm_build.py
python -B -m unittest discover -s tracker -p test_xm.py -v
python -B tracker/xm_verify.py --decode
```

Or, from this `tracker` directory:

```powershell
python -B xm_build.py
python -B -m unittest discover -s . -p test_xm.py -v
python -B xm_verify.py --decode
```

The builder writes only the XM and `build_report.json` under `tracker/`.
An alternate output can be selected with `--output tracker/alternate.xm` from
the parent directory; outputs outside `tracker/` are rejected. Verification
writes `verification.json` here. Its temporary seekable XM is also created here
and cleaned up after decoding. Decoded PCM goes to memory. `-B` avoids bytecode
cache writes; the source-import subprocess always disables bytecode writes too.
No existing demo, music, video, or publication file is modified.

Structural verification without FFmpeg:

```powershell
python -B tracker/xm_verify.py
```

Check the available decoder and inspect native metadata directly:

```powershell
ffmpeg -hide_banner -demuxers
ffprobe -v error -f libopenmpt -show_entries format=duration:format_tags -of json tracker/CRTkafa-cracktro-01.xm
ffmpeg -hide_banner -nostdin -f libopenmpt -sample_rate 44100 -i tracker/CRTkafa-cracktro-01.xm -f null -
```

## Native structure and naming

XM's fixed song-title field has only 20 bytes. The approved title in that field
is **CRTkafa cracktro 01** (19 ASCII characters, space-padded). Instrument 14 is
a sample-free metadata slot containing the exact full branding
**CRTkafa @ cracktro 01**. The README and build report retain that full text too.
There are no creator names, local machine paths, compressed sample extensions,
stereo-sample extensions, plugins, or appended non-XM chunks in the module.

Instruments 1–13 are lead, solo, harmony, bass, guitar, organ, pad, arp, bell,
kick, snare, hat, and crash. Instrument 14 holds the full title. Instruments
15–21 are sample-free section labels with zero-based order ranges. Bell uses
two pitch-specific samples so its two played pitches retain a four-second
sample duration; the other instruments each use one sample.

All samples are native signed 16-bit delta PCM. Sustained timbres use valid
forward loops and XM volume envelopes. Drums and bells are short synthesized
one-shots. Pitch, bass octave folding, pad inversions, organ chords, compound
drum triggers, and conditional bell/harmony attacks come from the verified
score. Guitar's root and fifth are separate notes; the sample does not add a
second power-chord fifth. The section labels also survive native playback as
instrument-name metadata.

## Mix and gain channels

The first decode was too quiet. The final native mix raises the original note
balance by approximately 7.6 dB while retaining section gains and fades. Sample
peaks use 92% of the signed PCM range. Note velocity still controls the level.

Native XM note volume stops at 64 and there is no portable module preamp field.
Lead, solo, harmony, bass, kick, snare, and crash therefore use phase-coherent
gain-partner channels. Each pair plays the same sample, pitch, panning, timing,
and key-off; the desired note level is split across two legal volume columns.
This is additive gain, not a new melody, echo, compressor, or external decoder
gain setting. Primary voices occupy channels 1–22; their gain partners use
channels 23–29. Channel 30 is spare; channels 31–32 carry global volume/tempo.
Numbers in Python's channel maps are zero-based.

The resulting file contains 3,750 native note-on cells, representing exactly
2,177 distinct instrument/pitch/time onsets: 1,398 musical notes plus 779 hits.
The additional 1,573 cells are the gain partners. Tests compare the primary
events to the score and independently verify that each partner matches its
primary, with every volume column in range.

## Timing and measured verification

The source grid is 5,000 samples per row at 44,100 Hz, or approximately
132.3 BPM with six ticks per row. Standard XM has integer BPM. Native `F84`
and `F85` commands alternate 132/133 BPM with error diffusion, rather than
letting a rounded constant BPM accumulate drift. `Gxx` controls the section
gain and fades; `8xx` sets panning; note 97 provides native key-off. No pattern
loops, jumps, delays, or format-specific playback extensions are used.

| Measurement | Result |
|---|---:|
| Source score duration | 174.149659864 s |
| XM tempo-derived duration | 174.149863295 s |
| Largest calculated row-boundary timing error | 0.421 ms |
| Full FFmpeg/libopenmpt decode, 44.1 kHz stereo | 7,680,324 frames / 174.157006803 s |
| Decoded sample peak | -2.925 dBFS |
| Decoded RMS | -19.643 dBFS |
| Decoded samples at or above full scale | 0 |
| Module size | 1,251,148 bytes |

The eleven automated tests cover native headers, order/pattern lengths, every
score note and drum hit, gain partners, key-offs, section timing, legal effects,
sample mappings, delta decoding, loop bounds/seams, pitch tuning, malformed-file
rejection, byte-identical rebuilding, and unchanged source hashes/timestamps.
Decoder tests render the entire file and an isolated concert-A tuning probe.
They enforce approximately -3 to -1 dBFS peak and -20 to -17 dBFS RMS for this
decoder configuration. The generated JSON reports contain exact values and
the module SHA-256. Decoder tests explicitly skip when libopenmpt is unavailable;
`xm_verify.py --decode` instead fails so a requested verification is not silently
omitted.

## Fidelity limits

This is an editable native-tracker reconstruction, not a bit-identical export
of the realtime DSP. Oscillator timbres, detune, filters, organ drawbars, and
drum synthesis are approximated with individual samples and native envelopes.
Transposing a sample changes its fixed spectral shape; realtime filter sweeps,
continuous oscillator phase across retriggers, FM brightness behavior, exact
sidechain pumping, delay, chorus, gated/hall reverb, risers, tape coloration,
and bus compression are not reproduced. No separate riser note is invented.

The visual score's conservative durations supply key-off positions. Decaying
instruments continue their native non-sustained envelope after key-off, while
held lead/bass/organ/pad envelopes release. Tracker tick-rate envelopes cannot
match the synth's sub-millisecond attack smoothing or exact gate curves. Note
replacement and three-note organ/pad channels can cut an outgoing release at
the next chord. Guitar double-taking and stereo effects are approximated by
panning and short sample detune, not an identical stereo signal.

The looped melodic samples' tuning quantization is about 0.303 cents flat;
the independent decoder tuning test confirms concert A within 0.5 Hz. The
row-clock bound is a mathematical tempo estimate, not a guarantee about every
player's tick rounding. Libopenmpt's reported container duration is about
174.122875 s; its actual decoded frame count above differs due to player timing
and end handling. Repeat settings can loop a module at its restart order;
the verified default decode plays one pass. Different players' interpolation,
mix gain, and ramping may change loudness or timbre. The standalone XM
reference render is decoder-based. The authentic companion
video described below uses the original DOS FastTracker II output instead.

## Authentic FastTracker II video capture

The rendered capture is published as video, not as a file in this
repository. What ships here is the module itself and the chain that builds
and checks it, so the result is reproducible rather than merely watchable.

The companion tracker video is captured from an emulated 486DX2/66 booting an
unmodified MS-DOS 6.22 system and running the original FastTracker II 2.08.
The boot disk is assembled by `prepare_dos622.py` from user-supplied DOS disk
images; Microsoft system files, 86Box, its ROM set, and FastTracker II are not
redistributed here.

`capture_native_86box.ps1` records one 86Box session as lossless window video
plus WASAPI loopback from the endpoint receiving 86Box's emulated Sound Blaster
16 output. The endpoint is muted only at the physical output while loopback is
active, then its prior mute state is restored. `render_86box_capture.ps1`
requires both files to come from that same session and refuses reference or
external soundtracks.

The renderer crops only the 640x400 emulated VGA framebuffer, makes short jump
cuts through the real BIOS/DOS/floppy boot, and ends before FastTracker returns
from order `2F` to `00`. Native pixels are enlarged 5x with nearest neighbour
and centred in a 3840x2160 4:4:4 master, so tracker text stays sharp. No DOSBox
or 86Box interface, host desktop, emulator branding, loop, generated overlay,
or re-created tracker UI appears in the result. The native SB16 capture gets
only fixed gain compensation and a short ending fade.

The verified capture uses raw interval 83.42–256.79 seconds from both streams;
the last cut frame still shows order `2F`, while the first observed restart to
`00` appears approximately at 256.84–256.85 seconds. The
result is 3840x2160 at 60 fps, 181.550 seconds long, and has SHA-256
`613CFFA42F68D2C02549110021BE92F04562501D997E9B53357F8B6B821EDD88`.
`capture_verification.json` records the machine-readable verification results.

Example:

```powershell
.\capture_native_86box.ps1

.\render_86box_capture.ps1 `
  -Capture .\capture\86box-crtkafa-486\native-session-YYYYMMDD-HHMMSS\86box-window.mkv `
  -TrackerAudio .\capture\86box-crtkafa-486\native-session-YYYYMMDD-HHMMSS\ft2-sb16.wav `
  -Output .\CRTkafa-cracktro-01-fasttracker-authentic-4K.mp4
```

Format references: [XM 1.04 format specification](https://modland.com/pub/documents/format_documentation/FastTracker%202%20v2.04%20(.xm).html),
[OpenMPT native XM notes](https://wiki.openmpt.org/Development:_Formats/XM), and
[OpenMPT effect reference](https://wiki.openmpt.org/Manual:_Effect_Reference).
