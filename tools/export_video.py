"""Silent offline export; check BOTH pipeline processes before publishing the MP4."""
import json
import hashlib
import math
import os
from pathlib import Path
import subprocess
import wave
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]


def main():
    exe = ROOT / "gfxvideo.exe"
    inputs = [ROOT / name for name in ("gfx.c", "synth.h", "voices.h", "shots.h",
                                      "song_data.h", "cats_mesh.h", "tardis_mesh.h", "c64_font.h", "shaders.h")]
    inputs += list((ROOT / "fx").glob("*.hlsl")) + list((ROOT / "fx/out").glob("*.h"))
    inputs += list((ROOT / "fx").glob("*.hlsli"))
    # Each target rewrites identical FXC headers. A later release build does
    # not make the video executable stale; authored shader/include files do.
    authored = [p for p in inputs if p.name != "shaders.h" and p.parent.name != "out"]
    if any(p.stat().st_mtime_ns > exe.stat().st_mtime_ns for p in authored):
        raise RuntimeError("Stale video renderer: run makevideo_gpu.bat to rebuild first")
    def fingerprint():
        return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                for p in inputs + [exe]}
    provenance = fingerprint()
    subprocess.run([str(exe)], cwd=ROOT,
                   env={**os.environ, "CRTK_WAVONLY": "1"}, check=True)
    with wave.open(str(ROOT / "dump.wav"), "rb") as wav:
        assert (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) == (2, 2, 44100)
        duration = wav.getnframes() / wav.getframerate()
    expected = math.ceil(duration * 60)
    pending = ROOT / "CRTkafa.pending.mp4"
    env = dict(os.environ)
    env.pop("CRTK_WAVONLY", None)
    render = subprocess.Popen([str(exe)], cwd=ROOT, env=env, stdout=subprocess.PIPE)
    try:
        encode = subprocess.Popen([
            "ffmpeg", "-nostdin", "-y", "-hide_banner", "-loglevel", "warning", "-stats",
            "-f", "rawvideo", "-pixel_format", "bgra", "-video_size", "1280x720",
            "-framerate", "60", "-i", "pipe:0", "-i", str(ROOT / "dump.wav"),
            "-c:v", "libx264", "-preset", "medium", "-crf", "19",
            "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "256k",
            "-movflags", "+faststart", str(pending)], stdin=render.stdout, cwd=ROOT)
        render.stdout.close()
        encoder_status = encode.wait()
        renderer_status = render.wait()
        if encoder_status or renderer_status:
            raise RuntimeError(f"Export failed: renderer={renderer_status}, encoder={encoder_status}")
    finally:
        if render.poll() is None:
            render.terminate()
            render.wait()
    info = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", str(pending)]))
    video = next(s for s in info["streams"] if s["codec_type"] == "video")
    audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
    if int(video["nb_frames"]) != expected:
        raise RuntimeError(f"Incomplete video: expected {expected}, got {video['nb_frames']}")
    if abs(float(audio["duration"]) - duration) > 0.05:
        raise RuntimeError("Audio duration differs from source WAV")
    if fingerprint() != provenance:
        raise RuntimeError("Sources or renderer changed during export; not publishing")
    published = ROOT / "CRTkafa.mp4"
    try:
        pending.replace(published)
    except PermissionError:
        # A player may hold the previous delivery open on Windows. Do not
        # close it or destroy that file; publish the verified render separately.
        published = ROOT / ("CRTkafa-cracktro-1-" + datetime.now().strftime("%Y%m%d-%H%M%S") + ".mp4")
        pending.replace(published)
    provenance[published.name] = hashlib.sha256(published.read_bytes()).hexdigest()
    provenance["dump.wav"] = hashlib.sha256((ROOT / "dump.wav").read_bytes()).hexdigest()
    (ROOT / "export-provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    print(f"Verified export: {expected} frames, {duration:.3f} s, 1280x720, 60 fps", flush=True)
    print(f"Video: {published}", flush=True)


if __name__ == "__main__":
    main()
