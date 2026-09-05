"""Independent strict parser for this native XM subset, plus silent decoding.

python -B tracker/xm_verify.py --decode
No GUI or playback. FFmpeg renders to a memory pipe, not to demo/publication files.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

import numpy as np

HERE = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def text(data):
    require(all(byte == 0 or 32 <= byte < 127 for byte in data),"Non-ASCII metadata")
    value = data.decode("ascii").rstrip(" \x00")
    require(":" not in value and "\\" not in value and "/" not in value,"Path-like metadata")
    return value


def parse_xm(data):
    require(len(data) >= 336,"Truncated XM header")
    require(data[:17] == b"Extended Module: " and data[37] == 0x1A,"Invalid XM signature")
    title, tracker = text(data[17:37]), text(data[38:58])
    version,header_size,length,restart,channels,npatterns,ninstruments,flags,speed,bpm = struct.unpack_from("<HI8H",data,58)
    require(version == 0x104 and header_size == 276,"Expected native XM 1.04 full header")
    require(1 <= length <= 256 and 0 <= restart < length,"Invalid song length/restart")
    require(2 <= channels <= 32 and channels % 2 == 0,"Invalid native XM channel count")
    require(1 <= npatterns <= 256 and 1 <= ninstruments <= 128,"Invalid pattern/instrument count")
    require(flags in (0,1) and 1 <= speed <= 31 and 32 <= bpm <= 255,"Invalid flags/tempo")
    orders = list(data[80:80+length])
    require(all(order < npatterns for order in orders),"Invalid order reference")
    position = 60+header_size
    patterns = []
    for pattern in range(npatterns):
        require(position+9 <= len(data),"Truncated pattern header")
        hsize,packing,rows,size = struct.unpack_from("<IBHH",data,position)
        require(hsize == 9 and packing == 0 and 1 <= rows <= 256,"Invalid pattern header")
        position += hsize
        end = position+size
        require(end <= len(data),"Truncated pattern body")
        cells = []
        if size == 0:
            cells = [[0]*5 for _ in range(rows*channels)]
        else:
            for _ in range(rows*channels):
                require(position < end,"Too few pattern cells")
                first = data[position]
                position += 1
                cell = [0]*5
                if first & 0x80:
                    require(first & 0x60 == 0,"Invalid packed-cell mask")
                    for bit in range(5):
                        if first & (1<<bit):
                            require(position < end,"Truncated packed cell")
                            cell[bit] = data[position]
                            position += 1
                else:
                    require(position+4 <= end,"Truncated unpacked cell")
                    cell = [first]+list(data[position:position+4])
                    position += 4
                note,instrument,volume,effect,param = cell
                require(0 <= note <= 97 and instrument <= ninstruments,"Invalid note/instrument")
                require(volume == 0 or 0x10 <= volume <= 0x50,"Invalid volume in export subset")
                require(effect in (0,8,0xF,0x10),"Unexpected/non-native export effect")
                require(effect != 0 or param == 0,"Unexpected arpeggio effect")
                if effect == 0xF:
                    require(param != 0,"Ambiguous F00 is not allowed")
                if effect == 0x10:
                    require(param <= 64,"Gxx exceeds native global-volume range")
                cells.append(cell)
        require(position == end,"Pattern size does not match cell count")
        patterns.append(np.array(cells,dtype=np.uint8).reshape(rows,channels,5))
    instruments = []
    for index in range(ninstruments):
        require(position+29 <= len(data),"Truncated instrument header")
        hsize,name,kind,nsamples = struct.unpack_from("<I22sBH",data,position)
        require(hsize >= 29 and position+hsize <= len(data),"Invalid instrument-header extent")
        require(kind == 0 and nsamples <= 16,"Invalid native instrument/sample count")
        instrument = dict(name=text(name),samples=[],mapping=[],envelope=[],envelope_type=0)
        if nsamples:
            require(hsize == 263,"Expected full FT2 instrument header")
            sample_hsize = struct.unpack_from("<I",data,position+29)[0]
            require(sample_hsize == 40,"Invalid sample-header size")
            mapping = list(data[position+33:position+129])
            require(all(i < nsamples for i in mapping),"Invalid key-to-sample mapping")
            points = data[position+225]
            sustain = data[position+227]
            env_type = data[position+233]
            require(2 <= points <= 12 and env_type in (1,3),"Invalid volume envelope")
            envelope = [struct.unpack_from("<HH",data,position+129+i*4) for i in range(points)]
            require(all(v <= 64 for _,v in envelope),"Envelope volume out of range")
            require(all(a[0] < b[0] for a,b in zip(envelope,envelope[1:])),"Unordered envelope points")
            require(not env_type & 2 or sustain < points,"Invalid envelope sustain index")
            require(data[position+234] == 0,"Unexpected pan envelope")
            instrument.update(mapping=mapping,envelope=envelope,envelope_type=env_type,sustain=sustain)
        position += hsize
        headers = []
        for _ in range(nsamples):
            require(position+40 <= len(data),"Truncated sample header")
            size,loop_start,loop_length,volume,fine,kind,pan,relative,reserved,name = struct.unpack_from("<IIIBbBBbB22s",data,position)
            position += 40
            require(size > 0 and size % 2 == 0,"Invalid 16-bit sample length")
            require(kind in (0x10,0x11),"Only native mono 16-bit/forward-loop samples expected")
            require(0 <= volume <= 64 and -96 <= relative <= 95,"Sample volume/pitch out of range")
            require(loop_start % 2 == 0 and loop_length % 2 == 0,"Loop offsets are bytes, must align")
            if kind & 3:
                require(loop_length >= 4 and loop_start+loop_length <= size,"Invalid loop extent")
            else:
                require(loop_start == loop_length == 0,"Unlooped sample has loop data")
            sample_name = text(name)
            require(reserved == len(sample_name) <= 22,"Invalid native sample-name length")
            headers.append(dict(name=sample_name,bytes=size,loop_start=loop_start//2,
                                loop_length=loop_length//2,volume=volume,finetune=fine,
                                relative=relative,pan=pan))
        for sample in headers:
            end = position+sample["bytes"]
            require(end <= len(data),"Truncated delta sample data")
            delta = np.frombuffer(data[position:end],dtype="<i2")
            decoded = ((np.cumsum(delta,dtype=np.int64)+32768)%65536-32768).astype(np.int16)
            require(np.max(np.abs(decoded.astype(np.int32))) <= 30500,"Generated sample exceeds headroom limit")
            require(np.any(decoded),"Silent instrument sample")
            sample["pcm"] = decoded
            instrument["samples"].append(sample)
            position = end
        instruments.append(instrument)
    require(position == len(data),"Trailing non-native data or incorrect sample sizes")
    # Independently resolve every note's instrument and mapped sample.
    remembered = [0]*channels
    note_count = 0
    musical_onsets = set()
    elapsed, row_times = 0.0, [0.0]
    current_speed, current_bpm = speed,bpm
    for order_index,order in enumerate(orders):
        for row_index,row in enumerate(patterns[order]):
            for channel,cell in enumerate(row):
                note,ins,volume,effect,param = map(int,cell)
                if ins:
                    remembered[channel] = ins
                if 1 <= note <= 96:
                    require(remembered[channel] > 0,"Note without instrument")
                    inst = instruments[remembered[channel]-1]
                    require(bool(inst["samples"]),"Note references metadata-only instrument")
                    sample = inst["samples"][inst["mapping"][note-1]]
                    require(0 <= note-1+sample["relative"] <= 118,"Transposed note beyond native range")
                    note_count += 1
                    musical_onsets.add((order_index,row_index,remembered[channel],note))
                if effect == 0xF:
                    if param < 32:
                        current_speed = param
                    else:
                        current_bpm = param
            elapsed += current_speed*2.5/current_bpm
            row_times.append(elapsed)
    return dict(title=title,tracker=tracker,orders=orders,channels=channels,patterns=patterns,
                instruments=instruments,note_count=note_count,speed=speed,bpm=bpm,
                duration_seconds=elapsed,row_times=row_times,
                distinct_instrument_note_onsets=len(musical_onsets))


def decode_pcm(data, seconds=None):
    require(shutil.which("ffmpeg") is not None,"FFmpeg is not available")
    # This FFmpeg demuxer requires seekable input. Keep its scratch module
    # inside tracker/; decoded PCM still goes only to memory.
    with tempfile.TemporaryDirectory(prefix=".xm-verify-",dir=HERE) as scratch:
        module = Path(scratch)/"input.xm"
        module.write_bytes(data)
        command = ["ffmpeg","-hide_banner","-loglevel","error","-nostdin",
                   "-f","libopenmpt","-sample_rate","44100","-i",str(module)]
        if seconds is not None:
            command += ["-t",str(seconds)]
        command += ["-f","f32le","-acodec","pcm_f32le","-ac","2","pipe:1"]
        result = subprocess.run(command,capture_output=True,timeout=120)
        require(result.returncode == 0,"FFmpeg decode failed: "+result.stderr.decode(errors="replace"))
    require(len(result.stdout)%8 == 0,"Invalid decoded float-frame size")
    samples = np.frombuffer(result.stdout,dtype="<f4").reshape(-1,2)
    require(len(samples)>0 and np.all(np.isfinite(samples)),"Empty/nonfinite module decode")
    return samples


def summary(data, decoded=False):
    parsed = parse_xm(data)
    result = dict(title=parsed["title"],tracker=parsed["tracker"],channels=parsed["channels"],
                  patterns=len(parsed["patterns"]),orders=len(parsed["orders"]),
                  rows=[len(p) for p in parsed["patterns"]],
                  instruments=len(parsed["instruments"]),
                  instrument_names=[i["name"] for i in parsed["instruments"]],
                  samples=sum(len(i["samples"]) for i in parsed["instruments"]),
                  note_on_events=parsed["note_count"],duration_seconds=parsed["duration_seconds"],
                  distinct_instrument_note_onsets=parsed["distinct_instrument_note_onsets"],
                  bytes=len(data),sha256=hashlib.sha256(data).hexdigest())
    if decoded:
        pcm = decode_pcm(data)
        peak = float(np.max(np.abs(pcm)))
        rms = float(np.sqrt(np.mean(pcm.astype(np.float64)**2)))
        result["decode"] = dict(decoder="FFmpeg libopenmpt",rate=44100,frames=len(pcm),
                                seconds=len(pcm)/44100,peak_dbfs=20*math.log10(max(peak,1e-12)),
                                rms_dbfs=20*math.log10(max(rms,1e-12)),
                                full_scale_samples=int(np.count_nonzero(np.abs(pcm)>=1.0)))
        require(peak > .001 and rms > .0001,"Unexpected silent/near-silent decode")
        require(peak < 1.0,"Decode exceeds full scale")
        require(parsed["duration_seconds"]-.25 <= len(pcm)/44100 <= parsed["duration_seconds"]+10,
                "Decoded duration outside song plus player-tail allowance")
        result["decode"]["order_rms_dbfs"] = []
        for first in range(0,48*32,32):
            a,b = (round(parsed["row_times"][i]*44100) for i in (first,first+32))
            rms = float(np.sqrt(np.mean(pcm[a:b].astype(np.float64)**2)))
            result["decode"]["order_rms_dbfs"].append(20*math.log10(max(rms,1e-12)))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("module",nargs="?",type=Path,default=HERE/"CRTkafa-cracktro-01.xm")
    parser.add_argument("--decode",action="store_true")
    args = parser.parse_args()
    result = summary(args.module.read_bytes(),args.decode)
    (HERE/"verification.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    print(json.dumps(result,indent=2))


if __name__ == "__main__":
    main()
