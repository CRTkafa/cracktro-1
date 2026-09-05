"""Verify final offline artifacts and record exact source/artifact hashes."""
from array import array
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import wave

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    provenance = json.loads((ROOT / "export-provenance.json").read_text())
    for name, digest in provenance.items():
        assert sha(ROOT / name) == digest, f"Export no longer matches: {name}"
    videos = [ROOT / name for name in provenance if name.lower().endswith(".mp4")]
    assert len(videos) == 1, "Expected exactly one published video in provenance"
    video_path = videos[0]
    test = (ROOT / "gputest.txt").read_text()
    if "failures: 0" not in test:
        raise RuntimeError("Offline renderer tests have not passed")
    with wave.open(str(ROOT / "dump.wav"), "rb") as wav:
        frames, rate = wav.getnframes(), wav.getframerate()
        assert (wav.getnchannels(), wav.getsampwidth(), rate) == (2, 2, 44100)
        pcm = array("h", wav.readframes(frames))
    if sys.byteorder != "little":
        pcm.byteswap()
    peak = max(abs(min(pcm)), abs(max(pcm)))
    assert 0 < peak < 32767, f"Invalid/clipped PCM peak {peak}"
    assert max(map(abs, pcm[-882:])) <= 8, "Final 10 ms must approach silence"
    assert max(map(abs, pcm[:882])) <= 8, "Opening 10 ms must approach silence"
    info = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-of", "json", str(video_path)]))
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    assert int(video["nb_frames"]) == (frames * 60 + rate - 1) // rate
    assert (video["width"], video["height"], video["r_frame_rate"]) == (1280, 720, "60/1")
    assert abs(float(audio["duration"]) - frames / rate) < .05
    subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i",
                    str(video_path), "-f", "null", "-"], check=True)
    sources = [ROOT / "gfx.c", ROOT / "synth.h", ROOT / "voices.h", ROOT / "song_data.h",
               ROOT / "shots.h", ROOT / "cats_mesh.h", ROOT / "tardis_mesh.h", ROOT / "c64_font.h", ROOT / "shaders.h"]
    sources += sorted((ROOT / "fx").glob("*.hlsl")) + sorted((ROOT / "fx/out").glob("*.h"))
    sources += sorted((ROOT / "fx").glob("*.hlsli"))
    artifacts = [ROOT / name for name in ("CRTkafa.exe", "gfxvideo.exe", "gfxoffline.exe")]
    artifacts += [video_path, ROOT / "dump.wav"]
    # Generated headers are rewritten for every build, so freshness is checked
    # against authored source, not the last build's identical generated files.
    authored = [p for p in sources if p.name != "shaders.h" and p.parent.name != "out"]
    newest = max(p.stat().st_mtime_ns for p in authored)
    for p in artifacts[:3]:
        assert p.stat().st_mtime_ns >= newest, f"Stale executable: {p.name}"
    assert (ROOT / "gputest.txt").stat().st_mtime_ns >= (ROOT / "gfxoffline.exe").stat().st_mtime_ns
    record = {"duration_seconds": frames / rate, "video_frames": int(video["nb_frames"]),
              "pcm_peak": peak, "offline_failures": 0, "full_video_decode": "passed",
              "interactive_gui_tested": False,
              "sources": {str(p.relative_to(ROOT)): sha(p) for p in sources},
              "artifacts": {p.name: {"bytes": p.stat().st_size, "sha256": sha(p)} for p in artifacts}}
    (ROOT / "delivery.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({k: v for k, v in record.items() if k not in ("sources", "artifacts")}, indent=2))


if __name__ == "__main__":
    main()
