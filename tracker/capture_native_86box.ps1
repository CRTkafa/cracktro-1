param(
    [string]$OutputDevice = "Mi monitor",
    [int]$CaptureSeconds = 340
)

$ErrorActionPreference = "Stop"
$trackerRoot = $PSScriptRoot
$vmRoot = Join-Path $trackerRoot "capture\86box-crtkafa-486"
$audioExe = Join-Path $trackerRoot "capture\audio-loopback\bin\Release\net9.0-windows\AudioLoopback.exe"
$boxExe = Join-Path $env:LOCALAPPDATA "CRTkafa\86Box-v6.0\86Box.exe"
$boxHome = Split-Path -Parent $boxExe
$boxRoms = Join-Path $boxHome "roms\roms-6.0"
$boxAssets = Join-Path $boxHome "assets"

if (@(Get-Process 86Box -ErrorAction SilentlyContinue).Count -ne 0) {
    throw "Exactly one clean emulator session is required; 86Box is already running."
}
foreach ($required in @($audioExe, $boxExe, (Join-Path $vmRoot "86box.cfg"))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required capture input is missing: $required"
    }
}
if (-not (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    throw "ffmpeg.exe is required."
}

$stamp = [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss")
$session = Join-Path $vmRoot ("native-session-" + $stamp)
New-Item -ItemType Directory -Path $session | Out-Null
$audioPath = Join-Path $session "ft2-sb16.wav"
$videoPath = Join-Path $session "86box-window.mkv"
$audioLog = Join-Path $session "audio.log"
$audioErr = Join-Path $session "audio.err.log"
$videoLog = Join-Path $session "video.log"
$videoErr = Join-Path $session "video.err.log"

# capture-muted preserves and restores the endpoint's prior mute state. WASAPI
# loopback still receives the samples, so the authentic guest mix is recorded
# without making the workstation audible.
$audio = Start-Process -FilePath $audioExe `
    -ArgumentList @("capture-muted", ('"' + $OutputDevice + '"'), "$CaptureSeconds", ('"' + $audioPath + '"')) `
    -RedirectStandardOutput $audioLog -RedirectStandardError $audioErr `
    -WindowStyle Hidden -PassThru

Start-Sleep -Milliseconds 750
$box = Start-Process -FilePath $boxExe -WorkingDirectory $boxHome `
    -ArgumentList @("-R", $boxRoms, "-A", $boxAssets, "-P", $vmRoot) -PassThru
$deadline = (Get-Date).AddSeconds(20)
do {
    Start-Sleep -Milliseconds 200
    $box.Refresh()
} while ([string]::IsNullOrWhiteSpace($box.MainWindowTitle) -and (Get-Date) -lt $deadline)
if ([string]::IsNullOrWhiteSpace($box.MainWindowTitle)) {
    throw "86Box did not create a capturable window."
}

$windowTitle = $box.MainWindowTitle
$ffArgs = @(
    "-hide_banner", "-nostdin", "-y",
    "-f", "gdigrab", "-draw_mouse", "0", "-framerate", "60",
    "-i", ('"title=' + $windowTitle + '"'), "-t", "$CaptureSeconds",
    "-an", "-c:v", "ffv1", "-level", "3", "-g", "1", $videoPath
)
$video = Start-Process -FilePath "ffmpeg.exe" -ArgumentList $ffArgs `
    -RedirectStandardOutput $videoLog -RedirectStandardError $videoErr `
    -WindowStyle Hidden -PassThru

$manifest = [ordered]@{
    session = $session
    startedUtc = [DateTime]::UtcNow.ToString("o")
    outputDevice = $OutputDevice
    audioPid = $audio.Id
    videoPid = $video.Id
    vmPid = $box.Id
    windowTitle = $windowTitle
    audio = $audioPath
    video = $videoPath
}
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $session "session.json") -Encoding utf8
$manifest | ConvertTo-Json
