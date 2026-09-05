param(
    [Parameter(Mandatory = $true)]
    [string]$Capture,

    [Parameter(Mandatory = $true)]
    [string]$TrackerAudio,

    [double]$SongStart = 83.42,
    [double]$SongEnd = 256.79,

    [string]$Output = ".\CRTkafa-cracktro-01-fasttracker-authentic-4K.mp4"
)

$ErrorActionPreference = "Stop"

foreach ($inputPath in @($Capture, $TrackerAudio)) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Capture input not found: $inputPath"
    }
}
if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    throw "ffmpeg.exe is required."
}
if ($SongStart -lt 0 -or $SongEnd -le $SongStart) {
    throw "Invalid song boundaries."
}

$capturePath = (Resolve-Path -LiteralPath $Capture).Path
$audioPath = (Resolve-Path -LiteralPath $TrackerAudio).Path
$captureDir = Split-Path -Parent $capturePath
$audioDir = Split-Path -Parent $audioPath
if ($captureDir -ne $audioDir) {
    throw "Video and audio must come from the same native 86Box capture session."
}
if ([System.IO.Path]::GetFileName($audioPath) -ne "ft2-sb16.wav") {
    throw "Expected the native session file ft2-sb16.wav; external/reference audio is forbidden."
}
$outputPath = [System.IO.Path]::GetFullPath($Output)

# Five fast authentic cuts establish the physical-PC context without forcing
# viewers through the complete floppy boot. The final segment is the exact
# interval measured in both the scrolling FT2 rows and its captured SB16 audio.
$bootDuration = 8.2
$songDuration = $SongEnd - $SongStart
$fadeOutAt = $songDuration - 0.8
$finalFadeAt = $bootDuration + $songDuration - 0.6
$filter = @"
[0:v]crop=640:400:0:60,split=6[b0][b1][b2][b3][b4][song];
[b0]trim=start=2.1:end=4.2,setpts=PTS-STARTPTS[s0];
[b1]trim=start=4.9:end=6.0,setpts=PTS-STARTPTS[s1];
[b2]trim=start=7.7:end=9.0,setpts=PTS-STARTPTS[s2];
[b3]trim=start=16.0:end=17.4,setpts=PTS-STARTPTS[s3];
[b4]trim=start=80.0:end=82.3,setpts=PTS-STARTPTS[s4];
[song]trim=start=${SongStart}:end=${SongEnd},setpts=PTS-STARTPTS[s5];
[s0][s1][s2][s3][s4][s5]concat=n=6:v=1:a=0,
fps=60,scale=3200:2000:flags=neighbor,
pad=3840:2160:320:80:black,
fade=t=in:st=0:d=0.15,
fade=t=out:st=${finalFadeAt}:d=0.60,
format=yuv444p[v];
[1:a]atrim=start=${SongStart}:end=${SongEnd},asetpts=PTS-STARTPTS,
volume=15dB,
afade=t=in:st=0:d=0.03,afade=t=out:st=${fadeOutAt}:d=0.80[songa];
anullsrc=channel_layout=stereo:sample_rate=48000:d=$bootDuration[silence];
[silence][songa]concat=n=2:v=0:a=1,apad=pad_dur=0.05[a]
"@ -replace "`r?`n", ""

& ffmpeg.exe -hide_banner -nostdin -y `
    -i $capturePath -i $audioPath `
    -filter_complex $filter `
    -map "[v]" -map "[a]" `
    -c:v libx264 -preset slow -crf 10 -profile:v high444 `
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 `
    -c:a aac -b:a 320k -ar 48000 `
    -metadata title="CRTkafa @ cracktro 01 - FastTracker II" `
    -metadata comment="Native FastTracker II 2.08 / Sound Blaster 16 capture" `
    -movflags +faststart -shortest $outputPath

if ($LASTEXITCODE -ne 0) {
    throw "ffmpeg failed with exit code $LASTEXITCODE"
}

Get-Item -LiteralPath $outputPath
