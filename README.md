# crtkafa, cracktro #1 🐈‍⬛🌀

![CRTkafa inside the spiral](assets/cover.jpg)

**Windows x64 · Direct3D 11**

A standalone real-time demo. The music is synthesized as it runs;
shaders and model data are embedded in the executable.

## Run

Download [CRTkafa.exe](https://github.com/CRTkafa/cracktro-1/releases/download/v1.0.0/CRTkafa.exe)
from the [release](https://github.com/CRTkafa/cracktro-1/releases/tag/v1.0.0).
No installation, archive extraction, or companion assets needed.

| Key | Action |
| --- | --- |
| **F** | Fullscreen / windowed |
| **ESC** | Quit |
| **G** | Cycle flash intensity: reduced / disabled / full |

Starts fullscreen. Losing focus or dragging/resizing pauses sound and picture
together. The sequence ends; it does not loop.

Windows 10/11, 64-bit. Requires Direct3D feature level 11.0. A Windows WARP
software fallback is available, but may be slow.

**Contains flashing lights and moving high-contrast patterns.** Reduced flash
settings do not remove every high-contrast or moving element.

## Files

Release downloads are separate files, not a ZIP:

- **CRTkafa.exe** — the demo.
- **CRTkafa.nfo** — ASCII artwork and release information. Open in a monospace font.
- **RUNME.txt** — controls, requirements and playback notes.
- **CREDITS.md** — model creators, licenses and modifications.

The C engine, HLSL shaders, synthesizer, score and baked model data are included.
Model data comes from the creators listed in [CREDITS.md](CREDITS.md);
please retain their attribution when redistributing.

Release checks cover silent rendering, audio measurements and complete video
decoding. Interactive window/audio playback and a listening-based mix review
have not been verified.

## Build

Install Visual Studio with the **Desktop development with C++** workload and
a Windows SDK containing `fxc.exe`. Python 3 is needed only for score tools
and tests; video export also needs FFmpeg on `PATH`.

The build script checks the default Community-edition paths for Visual Studio
2022 and Visual Studio 18. For another edition or install location, update the
`VS` path near the top of `buildgfx.bat`.

```bat
buildgfx.bat
```

This compiles the shaders and produces `CRTkafa.exe`. Generated shader headers
are build outputs, not checked-in source. No downloaded models are needed to
build: the converted mesh tables are already included.

```bat
python -m unittest discover -s tools -p "test_*.py"
python tools/export_song.py --check
buildgfx.bat offline
```

`gfxoffline.exe` runs silent graphics tests and writes diagnostic frames.
`makevideo_gpu.bat` builds the video renderer and exports without playback.
The optional `tools/audio_audit.py` analyzer needs NumPy.

---

[crt.fyi](https://crt.fyi) · [hi@crt.fyi](mailto:hi@crt.fyi)
