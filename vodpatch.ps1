<#
.SYNOPSIS
    Recover the missing beginning of a local master recording from a stream VOD
    and prepend it, without re-encoding the master.

.DESCRIPTION
    A session was recorded twice: locally (high bitrate, the good master) and by
    a streaming platform (compressed VOD). The local recorder was started late,
    so the master is missing its first minutes. This script finds the exact time
    offset between the two files, re-encodes only the missing opening from the VOD
    to match the master's codec / resolution / fps / pixel format, and joins the
    two with the concat demuxer so the master is stream-copied byte for byte.

    Stages:
      analyze     find the offset (read-only)
      seamtest    render a short clip centred on the cut, to watch first
      merge       build the final file
      stripmerge  fallback route when the opening cannot be given the master's
                  stream layout (see README, "The timecode track")
      doctor      environment / input / join diagnostics

.NOTES
    Requires Windows PowerShell 5.1 and ffmpeg + ffprobe on PATH (or in one of
    the fallback locations below). No other dependencies.

    The ffmpeg build must include libx264, which means a GPL-enabled build
    (configure shows --enable-gpl --enable-libx264). An LGPL-only build has no
    libx264 and the merge stage fails with "Unknown encoder 'libx264'".

    ffmpeg is NOT distributed with this program. It is a separate work under
    its own licence, invoked here as an external process.

    Several things here look like odd style choices and are not. They are
    marked "CONSTRAINT n", explained in the README, and each one cost hours to
    find. Do not "clean them up".

.LINK
    https://www.gnu.org/licenses/gpl-3.0.html

    ------------------------------------------------------------------------
    vodpatch - recover the missing beginning of a recording from a stream VOD
    Copyright (C) 2026  Deployer <https://github.com/DDeploy>

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <https://www.gnu.org/licenses/>.
    ------------------------------------------------------------------------
#>
# SPDX-License-Identifier: GPL-3.0-or-later
# SPDX-FileCopyrightText: 2026 Deployer <https://github.com/DDeploy>

param(
    [ValidateSet("menu", "analyze", "seamtest", "merge", "stripmerge", "doctor")]
    [string]$Stage = "menu",

    [string]$Root   = "",                       # folder holding the two sources
    [string]$Vod    = "",                       # the stream VOD (auto-detected if omitted)
    [string]$Master = "",                       # the good local recording
    [string]$Out    = "",                       # final output path
    [string]$Work   = "",                       # scratch folder (default: <Root>\merge_work)
    [string]$Strip  = "",                       # stripmerge: timecode-free copy of the master

    [double]$Pre    = 90,                       # seamtest: seconds of VOD before the cut
    [double]$Post   = 90,                       # seamtest: seconds of master after it

    [double]$AudioShift = 0,                    # shift the opening's audio against its video,
                                                #   seconds; > 0 delays, < 0 advances
    [double]$Offset = [double]::NaN,            # skip analysis, use this offset
    [switch]$Force                              # ignore any cached opening
)

# CONSTRAINT 1 -- deliberately NOT "Stop".
# With $ErrorActionPreference = "Stop", PowerShell turns every line ffmpeg
# writes to stderr into a fatal terminating error and kills the script, even
# for harmless warnings. Every ffmpeg call goes through the FF wrapper below,
# which checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

$StartCwd = (Get-Location).Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# The card gets a different drive letter on every machine it is plugged into,
# so derive the root from where this script actually lives.
if (-not $Root) {
    $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
}
if (-not $Root.EndsWith("\")) { $Root += "\" }

function Resolve-UserPath([string]$p) {
    # Resolve a user-supplied path against the directory the user launched
    # from, NOT against the work directory we Push-Location into below. A bare
    # "merged.mp4" must not quietly land inside merge_work on the source card.
    if (-not $p) { return "" }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $StartCwd $p }
    return [System.IO.Path]::GetFullPath($p)
}

$Vod     = if ($Vod)    { Resolve-UserPath $Vod }    else { Join-Path $Root "twitch.mp4" }
$Master  = if ($Master) { Resolve-UserPath $Master } else { Join-Path $Root "HyperDeck_0001.mp4" }
$WorkDir = if ($Work)   { Resolve-UserPath $Work }   else { Join-Path $Root "merge_work" }

# Finished files go in their own folder rather than loose next to the script,
# so the result is never mistaken for one of the sources.
#
# The output container matches the SOURCE container by default. Writing an
# MP4-sourced H.264 + PCM pair into MOV made the muxer bail out after ~800 MB.
$ExportDir = Join-Path $Root "exported"
$OutFile   = if ($Out) { Resolve-UserPath $Out } else { Join-Path $ExportDir "full_recording.mp4" }

# The work folder has to be creatable, writable, and a path Windows will accept
# as a process current directory (CONSTRAINT 3 below depends on that). Unzip
# this into Program Files, or onto a network share, and none of those hold:
# Win32 SetCurrentDirectory does not support UNC paths at all. Fall back to the
# user's temp folder rather than failing somewhere deep in a filter graph.
function Test-UsableWorkDir([string]$dir) {
    if (-not $dir) { return $false }
    if ($dir.StartsWith("\\")) { return $false }        # UNC cannot be a cwd
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $dir ("._write_test_" + [guid]::NewGuid().ToString("N"))
        [System.IO.File]::WriteAllText($probe, "x")
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

$WorkDirFallback = $false
if (-not (Test-UsableWorkDir $WorkDir)) {
    $tag = [Math]::Abs($Root.ToLower().GetHashCode()).ToString("x8")
    $WorkDir = Join-Path $env:TEMP ("vodpatch\" + $tag)
    $WorkDirFallback = $true
    New-Item -ItemType Directory -Force -Path $WorkDir -ErrorAction SilentlyContinue | Out-Null
}
$VerifyDir = Join-Path $WorkDir "verify"
$SyncFile  = Join-Path $WorkDir "sync_result.txt"
$StampFile = Join-Path $WorkDir "opening_stamp.txt"

# Same question for the log: a read-only folder must not cost you the log.
$Log = Join-Path $Root ("{0}_log.txt" -f $Stage)
try { [System.IO.File]::AppendAllText($Log, "") } catch { $Log = Join-Path $WorkDir ("{0}_log.txt" -f $Stage) }

New-Item -ItemType Directory -Force -Path $VerifyDir | Out-Null

# CONSTRAINT 3 -- run from inside the work dir.
# An absolute Windows path inside an ffmpeg FILTER option string breaks the
# parser, because ':' is the option separator: in
# "metadata=print:file=D:\x\y.txt" the drive-letter colon is read as the start
# of a new option and the filter graph fails to parse. Filter outputs therefore
# use bare relative filenames, which only works when the process current
# directory is the work dir. Normal -i and output arguments are unaffected and
# keep using absolute paths.
Push-Location $WorkDir
[System.IO.Directory]::SetCurrentDirectory($WorkDir)

function Finish([int]$code) {
    Pop-Location -ErrorAction SilentlyContinue
    [System.IO.Directory]::SetCurrentDirectory($StartCwd)
    exit $code
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$Utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false

function Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format "HH:mm:ss"), $msg
    # Appended, never truncated: a failed multi-hour merge's log has to survive
    # the next attempt.
    try { [System.IO.File]::AppendAllText($Log, $line + [Environment]::NewLine, $Utf8NoBom) } catch { }
    Write-Host $line
}

Log ("=" * 70)
Log ("{0} -- stage '{1}'" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Stage)
if ($WorkDirFallback) {
    Log ("NOTE: this folder cannot hold the work files (read-only, or a network")
    Log ("      share, which Windows will not accept as a working directory).")
    Log ("      Using {0} instead." -f $WorkDir)
}

# CONSTRAINT 2 -- every number handed to ffmpeg must be invariant-culture.
# On a French-locale Windows, 147.5 stringifies as "147,5" through the -f
# format operator or a bare .ToString(), and ffmpeg misparses it silently.
# Use F() for every fractional argument and FI() for every integer one.
function F($x) {
    $d = [double]$x
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return "nan" }
    return $d.ToString("0.######", [System.Globalization.CultureInfo]::InvariantCulture)
}
function FI($x) {
    return ([long]$x).ToString([System.Globalization.CultureInfo]::InvariantCulture)
}

# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------
function Resolve-Tool($name) {
    # Portable first: an ffmpeg.exe sitting next to this script (or in .\bin or
    # .\ffmpeg\bin) wins over anything installed system-wide, so the whole tool
    # can be unzipped onto a stick with its own ffmpeg and carried around.
    $local = @(
        (Join-Path $Root "$name.exe"),
        (Join-Path $Root "bin\$name.exe"),
        (Join-Path $Root "ffmpeg\$name.exe"),
        (Join-Path $Root "ffmpeg\bin\$name.exe")
    )
    foreach ($c in $local) { if (Test-Path -LiteralPath $c) { return (Resolve-Path -LiteralPath $c).Path } }

    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        "C:\ffmpeg\bin\$name.exe",
        "$env:ProgramFiles\ffmpeg\bin\$name.exe",
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links\$name.exe"
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return (Resolve-Path $c).Path } }
    return $null
}

$ffmpeg  = Resolve-Tool "ffmpeg"
$ffprobe = Resolve-Tool "ffprobe"
if (-not $ffmpeg -or -not $ffprobe) {
    Log "ERROR: ffmpeg/ffprobe not found. Install ffmpeg and put it on PATH:"
    Log "       winget install Gyan.FFmpeg     (or https://www.gyan.dev/ffmpeg/builds/)"
    Finish 1
}

# The single place where ffmpeg is invoked. Captures output, never throws,
# reports the real exit code.
function FF([string[]]$cmdline, [string]$what) {
    $global:LASTEXITCODE = 0
    $out = & $ffmpeg @cmdline 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Log ("  ffmpeg exited {0} during: {1}" -f $LASTEXITCODE, $what)
        # CONSTRAINT 10 -- log the FIRST lines, not only the last.
        # The informative message is always first; the tail is generic "task
        # finished with error code" noise. Logging only the tail hid the real
        # cause for two rounds of debugging.
        $lines = $out -split "`r?`n" | Where-Object { $_.Trim() }
        foreach ($l in ($lines | Select-Object -First 6)) { Log ("  >  " + $l.Trim()) }
        if ($lines.Count -gt 9) {
            Log "  >  ..."
            foreach ($l in ($lines | Select-Object -Last 3)) { Log ("  >  " + $l.Trim()) }
        }
        return $false
    }
    return $true
}

function Probe($path) {
    $global:LASTEXITCODE = 0
    $json = & $ffprobe -v error -print_format json -show_format -show_streams $path 2>&1
    if ($LASTEXITCODE -ne 0) {
        Log ("  ffprobe failed (exit {0}) on {1}" -f $LASTEXITCODE, $path)
        return $null
    }
    try   { return (($json -join "`n") | ConvertFrom-Json) }
    catch { Log ("  could not parse ffprobe output for {0}" -f $path); return $null }
}

# The recovered head is encoded with libx264, which is a GPL-licensed
# component: an LGPL-only ffmpeg build does not have it and the encode fails
# with "Unknown encoder 'libx264'". Check once, up front, with a clear message
# rather than letting the user discover it mid-merge.
function Test-X264() {
    $cfg = (& $ffmpeg -hide_banner -version 2>&1 | Out-String)
    return ($cfg -match '--enable-libx264')
}

function Get-VideoStream($info) { $info.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1 }
function Get-AudioStream($info) { $info.streams | Where-Object { $_.codec_type -eq "audio" } | Select-Object -First 1 }

# Every video file in a folder, biggest first.
function Get-VideoFiles([string]$dir) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return @() }
    return @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Extension -match '^\.(mp4|mov|mkv|ts|m4v|m2ts|mts|avi|webm|mxf|flv)$' } |
             Where-Object { $_.Name -notmatch '^(seam_test|full_recording|opening)' } |
             Sort-Object Length -Descending)
}

# If the default names are not there, guess from what is: the local master is
# the high-bitrate recording and the VOD is the compressed one, so the largest
# file is the master and the next largest is the VOD. Only used when it is
# unambiguous, and always reported so the user can see what was picked.
function Find-Sources() {
    $vids = Get-VideoFiles $Root
    if ($vids.Count -lt 2) { return $false }
    $guessMaster = $vids[0]
    $guessVod    = $vids[1]
    # A master that is not clearly bigger than the VOD is not a safe guess.
    if ($guessMaster.Length -lt ($guessVod.Length * 2)) { return $false }
    $script:Master = $guessMaster.FullName
    $script:Vod    = $guessVod.FullName
    return $true
}

function Require-Inputs() {
    $haveMaster = Test-Path -LiteralPath $Master
    $haveVod    = Test-Path -LiteralPath $Vod
    if ($haveMaster -and $haveVod) { return }

    # Work out which files they are from what is actually in the folder,
    # rather than insisting on any particular filename.
    if (-not $haveMaster -and -not $haveVod -and (Find-Sources)) {
        Log "Picked the two recordings by size:"
        Log ("  local recording (larger) : {0}  {1:N2} GB" -f [System.IO.Path]::GetFileName($Master), ((Get-Item -LiteralPath $Master).Length/1GB))
        Log ("  stream VOD    (smaller) : {0}  {1:N2} GB" -f [System.IO.Path]::GetFileName($Vod),    ((Get-Item -LiteralPath $Vod).Length/1GB))
        Log "  If that is the wrong way round, pass -Master and -Vod explicitly."
        return
    }

    Log "ERROR: could not find the two recordings."
    Log ("       looked in {0}" -f $Root)
    $others = @(Get-VideoFiles $Root | Select-Object -First 8)
    if ($others.Count -eq 0) {
        Log "       there are no video files there at all"
    } elseif ($others.Count -eq 1) {
        Log ("       only one video file there ({0}) - two are needed" -f $others[0].Name)
    } else {
        Log "       could not tell which two of these to use:"
        foreach ($o in $others) { Log ("         {0,-44} {1,8:N2} GB" -f $o.Name, ($o.Length/1GB)) }
    }
    Log ""
    Log "You need two recordings of the same session: the local one, and the"
    Log "stream VOD that has the beginning the local one is missing."
    Log "Put both in this folder, or say where they are:"
    Log '       vodpatch.ps1 -Stage analyze -Vod "E:\stream.mp4" -Master "E:\recording.mov"'
    Log "From the menu, press [F] to choose them."
    Finish 1
}

# ---------------------------------------------------------------------------
# Fast signal matching (inline C# -- PowerShell loops are far too slow for
# this) plus a free-space query that also works for UNC paths.
# ---------------------------------------------------------------------------
$cs = @'
using System;
using System.Runtime.InteropServices;

public static class Sig {
    // Normalised (Pearson) cross-correlation of ref over search. Returns the
    // best lag, or -1 when the search signal is shorter than the reference.
    // excludeRadius is in SAMPLES: callers derive it from their own sample
    // rate so that the "next best elsewhere" exclusion zone is a fixed number
    // of seconds rather than a fixed number of samples.
    public static int BestLag(double[] r, double[] s, int excludeRadius,
                              ref double best, ref double second) {
        int n = r.Length, m = s.Length;
        best = double.NegativeInfinity; second = double.NegativeInfinity;
        int bestLag = 0;
        if (n < 2 || m < n) return -1;
        double rm = 0; for (int i = 0; i < n; i++) rm += r[i]; rm /= n;
        double[] rz = new double[n]; double rn = 0;
        for (int i = 0; i < n; i++) { rz[i] = r[i] - rm; rn += rz[i] * rz[i]; }
        rn = Math.Sqrt(rn); if (rn <= 0) rn = 1e-9;
        double[] ps = new double[m + 1]; double[] ps2 = new double[m + 1];
        for (int i = 0; i < m; i++) { ps[i+1] = ps[i] + s[i]; ps2[i+1] = ps2[i] + s[i]*s[i]; }
        int lags = m - n;
        double[] sc = new double[lags + 1];
        for (int lag = 0; lag <= lags; lag++) {
            double sum  = ps[lag+n]  - ps[lag];
            double sum2 = ps2[lag+n] - ps2[lag];
            double mean = sum / n;
            double var  = sum2 - 2*mean*sum + n*mean*mean;
            // A window with (near) zero variance carries no information. The
            // one-pass variance above loses precision when the values are far
            // from zero and nearly constant (dB envelopes sit around -90), so
            // treat anything below a relative epsilon as "no signal" rather
            // than dividing by it.
            double scale = Math.Abs(sum2) + 1e-30;
            double c;
            if (var <= 1e-12 * scale) {
                c = 0.0;
            } else {
                double sn = Math.Sqrt(var);
                double dot = 0;
                for (int i = 0; i < n; i++) dot += rz[i] * (s[lag+i] - mean);
                c = dot / (rn * sn);
                if (c > 1.0) c = 1.0; else if (c < -1.0) c = -1.0;
            }
            sc[lag] = c;
            if (c > best) { best = c; bestLag = lag; }
        }
        for (int lag = 0; lag <= lags; lag++) {
            if (Math.Abs(lag - bestLag) < excludeRadius) continue;
            if (sc[lag] > second) second = sc[lag];
        }
        if (double.IsNegativeInfinity(second)) second = 0.0;
        return bestLag;
    }

    // Slide a run of reference frames over a run of search frames, pick the
    // minimum mean absolute pixel difference. Raw 8-bit grey, frameBytes each.
    public static int BestFrameMatch(byte[] rf, byte[] sf, int frameBytes,
                                     int refCount, int searchCount, ref double bestDist) {
        bestDist = double.MaxValue; int bestLag = 0;
        int maxLag = searchCount - refCount;
        if (maxLag < 0) return -1;
        for (int lag = 0; lag <= maxLag; lag++) {
            long sad = 0;
            for (int f = 0; f < refCount; f++) {
                int ro = f * frameBytes;
                int so = (lag + f) * frameBytes;
                for (int k = 0; k < frameBytes; k++) {
                    int d = rf[ro+k] - sf[so+k];
                    sad += (d < 0 ? -d : d);
                }
            }
            double avg = (double)sad / (refCount * (double)frameBytes);
            if (avg < bestDist) { bestDist = avg; bestLag = lag; }
        }
        return bestLag;
    }
}

public static class Disk {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool GetDiskFreeSpaceEx(string dir, out ulong freeAvail,
                                          out ulong total, out ulong totalFree);
    // Bytes available to the caller, or -1 when it cannot be determined.
    // Works for drive letters, UNC shares and mapped drives alike, unlike
    // Get-PSDrive -Name <first character of the path>.
    public static long FreeBytes(string dir) {
        ulong avail, total, totalFree;
        if (GetDiskFreeSpaceEx(dir, out avail, out total, out totalFree)) return (long)avail;
        return -1;
    }
}
'@
Add-Type -TypeDefinition $cs -Language CSharp

# CONSTRAINT 4 -- input flags for the VOD.
# A platform VOD is stitched together from .ts segments and routinely carries
# duplicate DTS. These flags neutralise that on input.
$TsFix = @("-fflags", "+genpts+igndts")

# ---------------------------------------------------------------------------
# Free space
# ---------------------------------------------------------------------------
function Get-FreeBytes([string]$path) {
    if (-not $path) { return -1 }
    # Climb to the nearest directory that actually exists. The destination
    # folder is usually created only when something is about to be written, so
    # asking about it directly would report "unknown" when the drive is sitting
    # right there and perfectly measurable.
    $dir = $path
    while ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ($parent -eq $dir -or -not $parent) { break }
        $dir = $parent
    }
    if (-not $dir) { return -1 }
    try { return [Disk]::FreeBytes($dir) } catch { return -1 }
}

# Returns $true when it is safe to proceed. "Unknown" is reported as unknown
# and allowed through; "known and insufficient" stops the caller. The two must
# not be confused: an earlier version swallowed every failure, including a
# genuinely full disk, and another reported "0.0 GB free" whenever the path was
# not a plain drive letter.
function Test-FreeSpace([string]$path, [double]$needBytes, [string]$label) {
    $free = Get-FreeBytes $path
    if ($free -lt 0) {
        Log ("WARNING: could not determine free space for {0} ({1}); it needs about {2:N1} GB." -f $label, $path, ($needBytes/1GB))
        Log  "         Proceeding without the check."
        return $true
    }
    Log ("{0}: {1:N1} GB free, needs about {2:N1} GB." -f $label, ($free/1GB), ($needBytes/1GB))
    if ($free -lt $needBytes) { return $false }
    return $true
}

function Warn-SameDrive([string]$a, [string]$b) {
    try {
        if ([System.IO.Path]::GetPathRoot($a) -eq [System.IO.Path]::GetPathRoot($b)) {
            Log "WARNING: the output is on the same drive as the master. Reading and"
            Log "         writing the same removable card at once is pathologically slow"
            Log "         (~460 KB/s was measured). Pass -Out on a different physical drive."
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Extractors
# ---------------------------------------------------------------------------

# Per-frame scene-change score: how much each frame differs from the one before
# it. Static differences between the two sources (overlays, branding, grading)
# cancel out, leaving only the shared motion.
#
# CONSTRAINT 4 -- output goes to a rawvideo sink on NUL, NOT "-f null".
# The null muxer enforces strictly increasing timestamps and aborts with
# "Application provided invalid, non monotonically increasing dts" on VODs with
# duplicate DTS. rawvideo does not care. "-r" additionally forces constant
# frame rate at the muxer. Neither affects the scores, which are produced
# inside the filter graph beforehand.
function Get-SceneScores($path, $start, $duration, $tag, $fps) {
    $tmp = "scenes_$tag.txt"                       # CONSTRAINT 3: relative name
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $vf = "scale=160:90,scdet=t=0,metadata=print:key=lavfi.scd.score:file=$tmp,scale=16:16"
    $ok = FF (@("-hide_banner", "-loglevel", "error") + $TsFix +
              @("-ss", (F $start), "-t", (F $duration), "-i", $path,
                "-an", "-sn", "-dn", "-map", "0:v:0", "-vf", $vf,
                "-r", (F $fps), "-f", "rawvideo", "-pix_fmt", "gray", "-y", "NUL")) "scene scores ($tag)"

    $times  = New-Object System.Collections.Generic.List[double]
    $scores = New-Object System.Collections.Generic.List[double]
    $lastT = 0.0
    if (Test-Path $tmp) {
        foreach ($line in (Get-Content $tmp)) {
            if     ($line -match 'pts_time:([0-9.]+)')       { $lastT = [double]$Matches[1] }
            elseif ($line -match 'scd\.score=([0-9.eE+-]+)') { $times.Add($lastT); $scores.Add([double]$Matches[1]) }
        }
    }

    if ($times.Count -lt 10) {
        Log "  (scdet produced nothing for $tag - falling back to select/scene_score)"
        $tmp2 = "scenes2_$tag.txt"
        if (Test-Path $tmp2) { Remove-Item $tmp2 -Force }
        $vf2 = "scale=160:90,select='gte(scene\,0)',metadata=print:key=lavfi.scene_score:file=$tmp2,scale=16:16"
        $ok = FF (@("-hide_banner", "-loglevel", "error") + $TsFix +
                  @("-ss", (F $start), "-t", (F $duration), "-i", $path,
                    "-an", "-sn", "-dn", "-map", "0:v:0", "-vf", $vf2,
                    "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "-y", "NUL")) "scene scores fallback ($tag)"
        if (Test-Path $tmp2) {
            foreach ($line in (Get-Content $tmp2)) {
                if     ($line -match 'pts_time:([0-9.]+)')         { $lastT = [double]$Matches[1] }
                elseif ($line -match 'scene_score=([0-9.eE+-]+)')  { $times.Add($lastT); $scores.Add([double]$Matches[1]) }
            }
        }
    }

    # Report a short or truncated extraction rather than silently correlating
    # on a partial signal: a dead ffmpeg still leaves thousands of usable-
    # looking samples behind.
    $covered = if ($times.Count) { $times[$times.Count - 1] - $start } else { 0 }
    if (-not $ok) { Log ("  WARNING: the {0} scene-score pass reported an error." -f $tag) }
    if ($covered -lt ($duration * 0.9)) {
        Log ("  WARNING: {0} scene scores cover only {1:N1}s of the {2:N1}s requested." -f $tag, $covered, $duration)
    }
    return @{ times = $times; scores = $scores; ok = $ok; covered = $covered }
}

# RMS loudness envelope, for the independent audio cross-check.
#
# The pts_time of every measurement is kept. Dropping it and assuming the first
# sample sits at t=0 biases the entire audio answer by that stream's start
# time. On a VOD whose audio track starts at 0.02s while its video track starts
# at 0.95s, that bias is most of a second and shows up as the audio and video
# analyses "disagreeing" when in fact they agree to within one frame.
function Get-AudioEnvelope($path, $start, $duration, $stepSec, $tag) {
    $tmp = "env_$tag.txt"                          # CONSTRAINT 3: relative name
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $sr  = 8000
    $spp = [int][Math]::Round([double]$sr * $stepSec)
    $af  = "aresample=$sr,highpass=f=80,asetnsamples=n=${spp}:p=0,astats=metadata=1:reset=1,ametadata=print:key=lavfi.astats.Overall.RMS_level:file=$tmp"
    # CONSTRAINT 4 again: an s16le sink on NUL, not "-f null".
    $ok = FF (@("-hide_banner", "-loglevel", "error") + $TsFix +
              @("-ss", (F $start), "-t", (F $duration), "-i", $path,
                "-vn", "-sn", "-dn", "-map", "0:a:0", "-af", $af,
                "-f", "s16le", "-y", "NUL")) "audio envelope ($tag)"

    $times  = New-Object System.Collections.Generic.List[double]
    $scores = New-Object System.Collections.Generic.List[double]
    $lastT  = 0.0
    if (Test-Path $tmp) {
        foreach ($line in (Get-Content $tmp)) {
            if ($line -match 'pts_time:([0-9.]+)') { $lastT = [double]$Matches[1] }
            elseif ($line -match 'RMS_level=(-?[0-9.]+|-inf)') {
                $v = $Matches[1]
                $times.Add($lastT)
                if ($v -eq "-inf") { $scores.Add(-90.0) } else { $scores.Add([double]$v) }
            }
        }
    }
    return @{ times = $times; scores = $scores; ok = $ok }
}

function Get-RawFrames($path, $start, $duration, $tag, $w, $h, $fps) {
    $out = "frames_$tag.gray"                      # CONSTRAINT 3: relative name
    if (Test-Path $out) { Remove-Item $out -Force }
    $ok = FF (@("-hide_banner", "-loglevel", "error", "-y") + $TsFix +
              @("-ss", (F $start), "-t", (F $duration), "-i", $path,
                "-an", "-sn", "-dn", "-map", "0:v:0",
                "-vf", "scale=${w}:${h},format=gray", "-r", (F $fps),
                "-f", "rawvideo", "-pix_fmt", "gray", $out)) "raw frames ($tag)"
    if (-not $ok) { return $null }                 # do not match on a truncated buffer
    $p = Join-Path $WorkDir $out
    if (-not (Test-Path $p)) { return $null }
    return [System.IO.File]::ReadAllBytes($p)
}

# Put an irregular (time,value) series onto a uniform grid, in ABSOLUTE time.
# Zero-order hold; grid points before the first measurement take the first
# value rather than 0, so a signal that does not start at t=0 does not get an
# artificial step welded onto its front.
function Resample($sig, $duration, $hz) {
    # Floor, not [int]: PowerShell's [int] cast is banker's rounding
    # ([int]2.5 -> 2 but [int]3.5 -> 4), which makes the grid length wobble.
    $n = [int][Math]::Floor([double]$duration * $hz)
    if ($n -lt 1) { $n = 1 }
    $arr    = New-Object 'double[]' $n
    $times  = $sig.times
    $scores = $sig.scores
    $idx  = 0
    $last = if ($scores.Count -gt 0) { $scores[0] } else { 0.0 }
    for ($i = 0; $i -lt $n; $i++) {
        $t = $i / [double]$hz
        while ($idx -lt $times.Count -and $times[$idx] -le $t) { $last = $scores[$idx]; $idx++ }
        $arr[$i] = $last
    }
    return ,$arr
}

# ---------------------------------------------------------------------------
# Encoder arguments: make the prepended clip match the master as closely as
# possible, so the join can be a pure stream copy of the original.
# ---------------------------------------------------------------------------

# x264's profile names are not the strings ffprobe reports.
$ProfileMap = @{
    "constrained baseline"  = "baseline"
    "baseline"              = "baseline"
    "main"                  = "main"
    "high"                  = "high"
    "high 10"               = "high10"
    "high 10 intra"         = "high10"
    "high 4:2:2"            = "high422"
    "high 4:2:2 intra"      = "high422"
    "high 4:4:4 predictive" = "high444"
    "high 4:4:4 intra"      = "high444"
}
# ffprobe reports a DECODER name; a few of those are not encoder names.
$AudioEncMap = @{ "mp3" = "libmp3lame"; "vorbis" = "libvorbis"; "opus" = "libopus" }

function Get-EncodeArgs($v, $a) {
    # NOTE: not named $args. CONSTRAINT 8 -- $args is a reserved automatic
    # variable in PowerShell; using it as a local name corrupted the encoder
    # argument list once.
    $eargs = @("-c:v", "libx264", "-preset", "slow", "-crf", "10")
    if ($v.pix_fmt) { $eargs += @("-pix_fmt", $v.pix_fmt) }
    if ($v.profile) {
        $key = $v.profile.ToString().ToLower().Trim()
        if ($ProfileMap.ContainsKey($key)) {
            $eargs += @("-profile:v", $ProfileMap[$key])
        } else {
            Log ("  (unrecognised source profile '{0}' - letting x264 choose)" -f $v.profile)
        }
    }
    if ($v.r_frame_rate) { $eargs += @("-r", $v.r_frame_rate) }   # exact rational, e.g. 60000/1001
    $eargs += @("-vf", ("scale={0}:{1},setsar=1" -f (FI $v.width), (FI $v.height)))
    foreach ($pair in @(@("color_range","-color_range"), @("color_space","-colorspace"),
                        @("color_primaries","-color_primaries"), @("color_transfer","-color_trc"))) {
        $val = $v.($pair[0])
        if ($val -and $val -ne "unknown") { $eargs += @($pair[1], $val) }
    }

    $enc = $a.codec_name
    if ($AudioEncMap.ContainsKey($enc)) { $enc = $AudioEncMap[$enc] }
    $eargs += @("-c:a", $enc, "-ar", (FI $a.sample_rate), "-ac", (FI $a.channels))

    # Audio chain for the opening. Two things happen here and both matter at
    # the seam.
    #
    # asetpts=PTS-STARTPTS forces the audio to start at exactly 0. A VOD's
    # audio and video tracks often start at different times - measured on a
    # real Twitch VOD: video at 0.947s, audio at 0.020s - and without this the
    # re-encoded opening inherits the difference, so its audio runs 20 ms late
    # against its own picture for the whole recovered section.
    #
    # apad then guarantees the audio reaches the end of the video instead of
    # stopping short of it. Video is constant frame rate so it ends on a frame
    # boundary, audio ends on a sample boundary, and the container duration is
    # whichever ends last - which is where the concat demuxer puts the join.
    # Measured on the real job: 13.15 ms of discontinuity at the seam without
    # this, 0.5 ms with it. "-t" on the output trims the padding back, so no
    # silence is actually added.
    $achain = @("asetpts=PTS-STARTPTS")

    # Optional manual audio/video correction, applied to the opening only.
    if ($AudioShift -gt 0) {
        $ms = [int][Math]::Round($AudioShift * 1000)
        $achain += ("adelay={0}:all=1" -f (FI $ms))
        Log ("  audio shift: delaying the opening's audio by {0} ms" -f (FI $ms))
    } elseif ($AudioShift -lt 0) {
        $achain += ("atrim=start={0}" -f (F ([Math]::Abs($AudioShift))))
        $achain += "asetpts=PTS-STARTPTS"
        Log ("  audio shift: advancing the opening's audio by {0} s" -f (F ([Math]::Abs($AudioShift))))
    }
    $achain += "apad"
    $eargs += @("-af", ($achain -join ","))
    return $eargs
}

function Write-ConcatList($listPath, $first, $second) {
    # The concat demuxer reads this list as raw bytes and hands the names to
    # the Win32 API as UTF-8, so it must be UTF-8 WITHOUT a BOM:
    #   - "Out-File -Encoding ascii" silently replaces every accented character
    #     with '?', producing a path that does not exist;
    #   - "Out-File -Encoding utf8" in Windows PowerShell 5.1 writes a BOM,
    #     which turns the first line into "<BOM>file '...'" and fails to parse.
    # Inside single quotes ffmpeg treats everything literally except the quote
    # itself, so backslashes are fine and an apostrophe is escaped as '\''.
    # Each element is parenthesised on purpose. In PowerShell the comma
    # operator binds TIGHTER than '+', so writing
    #     @("file '" + $a + "'", "file '" + $b + "'")
    # parses as "file '" + $a + ("'", "file '") + $b + "'" -- the inner array
    # is flattened with a space and the whole thing collapses into a SINGLE
    # line, which the concat demuxer reads as one entry. The result is an
    # output containing only the first file, with no error anywhere.
    [string[]]$lines = @(
        ("file '" + ($first  -replace "'", "'\''") + "'"),
        ("file '" + ($second -replace "'", "'\''") + "'")
    )
    [System.IO.File]::WriteAllLines($listPath, $lines, $Utf8NoBom)
    if ((Get-Content -LiteralPath $listPath).Count -ne 2) {
        Log "ERROR: the concat list is not two lines. Refusing to continue."
        Finish 1
    }
}

function Get-JoinArgs($listPath) {
    return @("-f", "concat", "-safe", "0", "-i", $listPath,
             "-map", "0:v:0", "-map", "0:a:0", "-dn", "-sn", "-ignore_unknown",
             "-c", "copy")
}

# Temporary sibling of an output file: "out.mp4" -> "out.part.mp4".
# The suffix goes BEFORE the extension, not after it: ffmpeg picks the muxer
# from the extension, and "out.mp4.part" fails with "Unable to choose an output
# format for 'out.mp4.part'".
function Get-SiblingPath([string]$p, [string]$suffix) {
    $dir  = [System.IO.Path]::GetDirectoryName($p)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($p)
    $ext  = [System.IO.Path]::GetExtension($p)
    $name = $base + "." + $suffix + $ext
    if ($dir) { return (Join-Path $dir $name) }
    return $name
}

function Read-Offset() {
    if (-not [double]::IsNaN($Offset)) {
        Log ("Using the offset given on the command line: {0:N3}s" -f $Offset)
        return $Offset
    }
    if (-not (Test-Path -LiteralPath $SyncFile)) {
        Log "ERROR: no analysis result yet. Run 1-analyze.bat first, or pass -Offset <seconds>."
        Finish 1
    }
    $cfg = @{}
    foreach ($line in (Get-Content $SyncFile)) {
        if ($line -match '^([a-z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] }
    }
    if (-not $cfg.ContainsKey("offset")) { Log "ERROR: $SyncFile has no offset line."; Finish 1 }
    $o = 0.0
    if (-not [double]::TryParse($cfg["offset"], [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$o)) {
        Log ("ERROR: could not read the offset '{0}' from {1}." -f $cfg["offset"], $SyncFile)
        Finish 1
    }
    Log ("Using offset {0:N3}s (from analysis)" -f $o)
    return $o
}

function Assert-SaneOffset([double]$offset, [double]$vodDur) {
    if ($offset -le 0) {
        Log ("ERROR: the offset is {0:N3}s. It must be positive - it is how much of the VOD" -f $offset)
        Log  "       goes in front of the master. Re-run the analysis."
        Finish 1
    }
    if ($offset -ge $vodDur) {
        Log ("ERROR: the offset is {0:N3}s but the VOD is only {1:N3}s long." -f $offset, $vodDur)
        Finish 1
    }
}

# ---------------------------------------------------------------------------
# Opening construction, shared by merge and stripmerge
# ---------------------------------------------------------------------------

# Builds <work>\opening.mp4: the recovered head, re-encoded to match the
# master. It is cached, but a cache is only reused when it was built from the
# same offset, the same source and the same audio shift, AND its duration still
# matches. A half-written file from a failed or interrupted run is never
# reused: the encode goes to a .part file that is renamed only on success.
function New-Opening([double]$offset, $v, $a) {
    $seg  = Join-Path $WorkDir "opening.mp4"
    $part = Get-SiblingPath $seg "part"

    $stamp = ("offset={0}|audioshift={1}|vod={2}|vodsize={3}" -f `
              (F $offset), (F $AudioShift), $Vod, (FI (Get-Item -LiteralPath $Vod).Length))

    $reuse = $false
    if ((Test-Path -LiteralPath $seg) -and $Force) {
        Log "-Force given: rebuilding the opening."
    } elseif (Test-Path -LiteralPath $seg) {
        $stampOk = (Test-Path -LiteralPath $StampFile) -and
                   ((Get-Content -Raw -LiteralPath $StampFile).Trim() -eq $stamp)
        if (-not $stampOk) {
            Log "The cached opening was built from different settings - rebuilding."
        } else {
            $si = Probe $seg
            if (-not $si) {
                Log "The cached opening does not probe cleanly - rebuilding."
            } else {
                $sd = [double]$si.format.duration
                if ([Math]::Abs($sd - $offset) -lt 0.5) {
                    $reuse = $true
                    Log ("Reusing the cached opening: {0:N0} MB, {1:N3}s (pass -Force to rebuild)" -f ((Get-Item $seg).Length/1MB), $sd)
                } else {
                    Log ("The cached opening is {0:N3}s but the offset is {1:N3}s - rebuilding." -f $sd, $offset)
                }
            }
        }
    }

    if (-not $reuse) {
        if (-not (Test-X264)) {
            Log "ERROR: this ffmpeg build has no libx264, so the recovered head cannot be"
            Log "       encoded. libx264 is GPL-licensed, so you need a GPL-enabled build"
            Log "       (its configuration line shows --enable-gpl --enable-libx264)."
            Log "       winget install Gyan.FFmpeg  gives you one."
            Finish 1
        }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Log ("Encoding the recovered opening (VOD 0 - {0:N3}s)..." -f $offset)
        $encArgs = Get-EncodeArgs $v $a
        if (-not (FF (@("-y", "-hide_banner", "-loglevel", "warning") + $TsFix +
                      @("-i", $Vod, "-t", (F $offset)) + $encArgs + @($part)) "opening encode")) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
            Log "ERROR: the opening encode failed. The partial file was deleted."
            Log "Your originals are untouched."
            Finish 1
        }
        Remove-Item -LiteralPath $seg -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $part -Destination $seg -Force
        [System.IO.File]::WriteAllText($StampFile, $stamp, $Utf8NoBom)
        Log ("Opening written: {0:N0} MB" -f ((Get-Item $seg).Length / 1MB))
    }
    return $seg
}

# CONSTRAINT 5 -- give the opening the SAME stream layout as the master.
# The concat demuxer pairs streams by INDEX, not by type. A Blackmagic master
# is 0=video, 1=tmcd, 2=audio; a plain two-stream opening is 0=video, 1=audio.
# At the junction, concat therefore fed the master's 4-byte timecode packets
# into the audio track. A pcm_s24le stereo sample is 6 bytes, so ffmpeg
# computed 4/6 = 0 samples and died with "fatal error, input packet contains no
# samples" -> AVERROR_PATCHWELCOME (-1163346256). "-dn" on the OUTPUT does not
# help: the mis-pairing happens on INPUT.
#
# MP4 refuses to copy a tmcd track ("Could not find tag for codec none"), so
# the rebuilt opening has to be a MOV, with -write_tmcd 0 to suppress the
# second, automatic timecode track that movenc otherwise appends. A layout with
# extra TRAILING streams is acceptable: pairing starts at index 0, so only the
# leading streams have to line up.
function Add-MasterStreamLayout($rawSeg, $masterInfo) {
    $dataStream = ($masterInfo.streams | Where-Object { $_.codec_type -eq "data" } | Select-Object -First 1)
    $wantedList = @($masterInfo.streams | Sort-Object index | ForEach-Object { $_.codec_type })
    $wanted     = $wantedList -join ","

    if (-not $dataStream) {
        Log "The master has no extra data track; using the opening as it is."
        return $rawSeg
    }

    Log ("The master's layout is [{0}] - the opening has to match it." -f $wanted)
    Log "ffmpeg exposes a tmcd track with codec 'none', which a plain copy refuses,"
    Log "so several construction methods are tried on a 5s sample first."

    $probeRaw = Join-Path $WorkDir "probe_raw.mp4"
    FF @("-y", "-hide_banner", "-loglevel", "error", "-i", $rawSeg, "-t", "5",
         "-c", "copy", $probeRaw) "probe slice" | Out-Null

    $didx = $dataStream.index
    $methods = @(
        @{ n = "mov+write_tmcd0";    ext = "mov"; a = @("-write_tmcd", "0") },
        @{ n = "mov+cu+write_tmcd0"; ext = "mov"; a = @("-copy_unknown", "-write_tmcd", "0") },
        @{ n = "mov+no_metadata";    ext = "mov"; a = @("-map_metadata", "-1") },
        @{ n = "mov+copy_unknown";   ext = "mov"; a = @("-copy_unknown") },
        @{ n = "mov";                ext = "mov"; a = @() }
    )

    $winner = $null; $fallback = $null
    foreach ($m in $methods) {
        $po = Join-Path $WorkDir ("probe_tc." + $m.ext)
        Remove-Item -LiteralPath $po -Force -ErrorAction SilentlyContinue
        $call = @("-y", "-hide_banner", "-loglevel", "error",
                  "-i", $probeRaw, "-t", "5", "-i", $Master,
                  "-map", "0:v:0", "-map", ("1:" + (FI $didx)), "-map", "0:a:0",
                  "-c", "copy") + $m.a + @($po)
        $global:LASTEXITCODE = 0
        & $ffmpeg @call 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $po)) {
            Log ("  method [{0,-20}] -> rejected by ffmpeg" -f $m.n)
            continue
        }
        $pi = Probe $po
        if (-not $pi) {
            Log ("  method [{0,-20}] -> the output does not probe" -f $m.n)
            continue
        }
        $gotList = @($pi.streams | Sort-Object index | ForEach-Object { $_.codec_type })
        $got = $gotList -join ","
        $prefixOk = $gotList.Count -ge $wantedList.Count
        if ($prefixOk) {
            for ($i = 0; $i -lt $wantedList.Count; $i++) {
                if ($gotList[$i] -ne $wantedList[$i]) { $prefixOk = $false; break }
            }
        }
        if ($got -eq $wanted) {
            Log ("  method [{0,-20}] -> [{1}]  exact match" -f $m.n, $got)
            $winner = $m; break
        } elseif ($prefixOk) {
            Log ("  method [{0,-20}] -> [{1}]  usable (extra trailing track)" -f $m.n, $got)
            if (-not $fallback) { $fallback = $m }
        } else {
            Log ("  method [{0,-20}] -> [{1}]  wrong order" -f $m.n, $got)
        }
    }
    if (-not $winner -and $fallback) {
        $winner = $fallback
        Log ("No exact layout available; using [{0}], whose leading streams line up." -f $winner.n)
    }
    Remove-Item -LiteralPath $probeRaw -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $WorkDir "probe_tc.mov") -Force -ErrorAction SilentlyContinue

    if (-not $winner) {
        Log ""
        Log "None of the methods can reproduce the master's layout in the opening."
        Log "Use the fallback route instead: 4-stripmerge.bat, which removes the"
        Log "timecode track from a copy of the master so that both files are plain"
        Log "video+audio. It costs one extra full pass but cannot hit this problem."
        Log "Your originals are untouched."
        Finish 1
    }

    Log ("Using method [{0}] for the real opening..." -f $winner.n)
    $segment = Join-Path $WorkDir ("opening_tc." + $winner.ext)
    $part    = Get-SiblingPath $segment "part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    $call = @("-y", "-hide_banner", "-loglevel", "error",
              "-i", $rawSeg, "-t", "5", "-i", $Master,
              "-map", "0:v:0", "-map", ("1:" + (FI $didx)), "-map", "0:a:0",
              "-c", "copy") + $winner.a + @($part)
    if (-not (FF $call "opening restructure")) {
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Log "ERROR: rebuilding the full opening failed. Your originals are untouched."
        Finish 1
    }
    Remove-Item -LiteralPath $segment -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $part -Destination $segment -Force

    Log "The opening's stream layout is now:"
    $si = Probe $segment
    if ($si) {
        foreach ($s in $si.streams) {
            Log ("  #{0} {1,-8} {2,-12} tag={3}" -f $s.index, $s.codec_type, $s.codec_name, $s.codec_tag_string)
        }
    }
    return $segment
}

# CONSTRAINT 7 -- the preflight must run the REAL command.
# Earlier versions bounded it with -ss/-t, which perturbed exactly the
# behaviour under test and reported false PASSes twice, letting two multi-hour
# failures through. It is now bounded by bytes written (-fs), so the command is
# otherwise identical to the real one, and it asserts that the test output
# really did pass the seam before declaring success. Keep both properties.
#
# Two refinements on top of that:
#   - the byte budget is derived from the master's MEASURED bitrate instead of
#     being a fixed 150 MB, so "enough to get well past the seam" stays true
#     for a master of any bitrate;
#   - it is written to the REAL destination, so a destination-specific problem
#     (full disk, 4 GB FAT32 limit, denied permission) is caught here rather
#     than four hours in.
function Invoke-Preflight($listPath, [double]$offset, [double]$headBytes,
                          [double]$masterBytesPerSec, [string]$outFile) {
    $joinArgs    = Get-JoinArgs $listPath
    $secondsPast = 10.0
    $margin      = [long][Math]::Max(150MB, $masterBytesPerSec * $secondsPast)
    $fsLimit     = [long]($headBytes + $margin)
    $testOut     = Get-SiblingPath $outFile "preflight"

    Log "Preflight: the exact join command, stopped after the seam (by size)."
    Log ("  head {0:N0} MB + {1:N0} MB margin (~{2:N0}s of master at {3:N1} MB/s)" -f `
         ($headBytes/1MB), ($margin/1MB), $secondsPast, ($masterBytesPerSec/1MB))

    Remove-Item -LiteralPath $testOut -Force -ErrorAction SilentlyContinue
    $pfOk = $false
    if (FF (@("-y", "-hide_banner", "-loglevel", "error") + $joinArgs +
            @("-fs", (FI $fsLimit), $testOut)) "preflight real join") {
        $ti = Probe $testOut
        if (-not $ti) {
            Log "  FAIL - the test output does not probe."
        } else {
            $tdur = [double]$ti.format.duration
            # CONSTRAINT 4 -- decode checks go to raw sinks, not "-f null".
            $global:LASTEXITCODE = 0
            $errV  = & $ffmpeg -hide_banner -v error -i $testOut -map 0:v:0 -f rawvideo -pix_fmt gray -y NUL 2>&1 | Out-String
            $codeV = $LASTEXITCODE
            $global:LASTEXITCODE = 0
            $errA  = & $ffmpeg -hide_banner -v error -i $testOut -map 0:a:0 -f s16le -y NUL 2>&1 | Out-String
            $codeA = $LASTEXITCODE
            $errs  = ($errV.Trim() + "`n" + $errA.Trim()).Trim()
            if ($tdur -le ($offset + 2)) {
                Log ("  FAIL - the test only reached {0:N1}s; it never crossed the seam at {1:N1}s." -f $tdur, $offset)
                Log  "         The join stopped early - read the ffmpeg lines above."
            } elseif ($errs -or $codeV -ne 0 -or $codeA -ne 0) {
                Log ("  FAIL on decode: " + (($errs -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 4) -join "  //  "))
            } else {
                $pfOk = $true
                Log ("  PASS - crossed the seam and reached {0:N1}s, decodes clean." -f $tdur)
            }
        }
    }
    Remove-Item -LiteralPath $testOut -Force -ErrorAction SilentlyContinue
    return $pfOk
}

# CONSTRAINT 9 -- Windows does not refresh a file's size or mtime while ffmpeg
# holds it open, so progress cannot be read from the filesystem. That is what
# "-progress <file>" writes a file for. Do not remove it.
#
# The output is written to a .part file and renamed only on success, so a
# failed run never leaves a plausible-looking multi-gigabyte file behind.
function Invoke-FinalJoin($listPath, [string]$outFile, [string]$what) {
    $joinArgs = Get-JoinArgs $listPath
    $progress = Join-Path $WorkDir "progress.txt"
    $part     = Get-SiblingPath $outFile "part"
    Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
    Log ("Live progress is written to {0} (out_time / total_size); Explorer will" -f $progress)
    Log "not refresh the output file size while ffmpeg holds it open."
    $ok = FF (@("-y", "-hide_banner", "-loglevel", "warning", "-nostats",
                "-progress", $progress) + $joinArgs + @($part)) $what
    if (-not $ok) {
        $size = 0
        if (Test-Path -LiteralPath $part) { $size = (Get-Item -LiteralPath $part).Length }
        Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        Log ("ERROR: the join failed. The partial output ({0:N1} GB) was deleted." -f ($size/1GB))
        Log "Your originals are untouched."
        return $false
    }
    Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $part -Destination $outFile -Force
    return $true
}

# ============================================================================
# STAGE: ANALYZE
# ============================================================================
if ($Stage -eq "analyze") {

    Log "=== SYNC ANALYSIS (read-only - your originals are never written to) ==="
    Log "ffmpeg: $ffmpeg"
    Require-Inputs

    $masterInfo = Probe $Master
    $vodInfo    = Probe $Vod
    if (-not $masterInfo -or -not $vodInfo) { Log "ERROR: could not probe the inputs."; Finish 1 }

    $masterDur = [double]$masterInfo.format.duration
    $vodDur    = [double]$vodInfo.format.duration
    $v = Get-VideoStream $masterInfo
    $a = Get-AudioStream $masterInfo
    if (-not $v) { Log "ERROR: the master has no video stream."; Finish 1 }
    if ($masterDur -le 0 -or $vodDur -le 0) { Log "ERROR: could not read a duration from one of the inputs."; Finish 1 }

    $rfr = $v.r_frame_rate -split '/'
    $fps = [double]$rfr[0] / [double]$rfr[1]
    if ([double]::IsNaN($fps) -or [double]::IsInfinity($fps) -or $fps -le 0) {
        Log ("ERROR: could not read a frame rate from the master (r_frame_rate='{0}')." -f $v.r_frame_rate)
        Finish 1
    }

    Log ("Master: {0:N1}s, {1} {2}x{3} @ {4:N3} fps, {5}" -f $masterDur, $v.codec_name, $v.width, $v.height, $fps, $v.pix_fmt)
    Log ("VOD   : {0:N1}s" -f $vodDur)

    # Per-stream start times matter: if the VOD's audio and video tracks start
    # at different times, the two analyses below are measuring in two different
    # timelines unless both keep absolute timestamps (they do - see
    # Get-AudioEnvelope).
    Log "Stream start times (a VOD often has audio and video starting apart):"
    foreach ($pair in @(@("master", $masterInfo), @("VOD", $vodInfo))) {
        foreach ($s in ($pair[1].streams | Sort-Object index)) {
            Log ("  {0,-6} #{1} {2,-6} start={3}s  dur={4}s" -f $pair[0], $s.index, $s.codec_type, $s.start_time, $s.duration)
        }
    }

    $needBytes = [double](Get-Item -LiteralPath $Master).Length
    Log ("(A merge writing back to this folder would need about {0:N1} GB.)" -f ($needBytes/1GB))
    $free = Get-FreeBytes $Root
    if ($free -ge 0) { Log ("Free space on {0}: {1:N1} GB" -f $Root, ($free/1GB)) }
    else             { Log ("Free space on {0}: unknown" -f $Root) }

    # ---- 1. coarse: motion-energy correlation -------------------------------
    # The reference window is clamped to the VOD as well as to the master: if
    # it is longer than the VOD, the correlation has nowhere to slide and
    # silently returns lag 0.
    $refDur = [Math]::Min(90, [Math]::Min($masterDur - 1, $vodDur - 2))
    if ($refDur -lt 5) {
        Log ("ERROR: the VOD is only {0:N1}s long - too short to match against." -f $vodDur)
        Finish 1
    }
    Log ("Reading motion energy from the master (0-{0:N0}s)..." -f $refDur)
    $sigMaster = Get-SceneScores $Master 0 $refDur "master" $fps
    Log ("  {0} frames" -f $sigMaster.times.Count)
    Log ("Reading motion energy from the VOD (0-{0:N0}s)..." -f ($vodDur - 1))
    $sigVod = Get-SceneScores $Vod 0 ($vodDur - 1) "vod" $fps
    Log ("  {0} frames" -f $sigVod.times.Count)

    if ($sigMaster.times.Count -lt 50 -or $sigVod.times.Count -lt 50) {
        Log "ERROR: could not read per-frame scores from one of the files. Aborting."
        Finish 1
    }

    $hz = 100
    $refArr = Resample $sigMaster $refDur $hz
    $srcArr = Resample $sigVod ($vodDur - 1) $hz

    $best = 0.0; $second = 0.0
    $lag = [Sig]::BestLag($refArr, $srcArr, [int](1.0 * $hz), [ref]$best, [ref]$second)
    if ($lag -lt 0) {
        Log "ERROR: the VOD's motion signal is shorter than the reference window."
        Log "       The VOD is probably too short, or its video failed to decode."
        Finish 1
    }
    $coarseOffset = $lag / [double]$hz
    Log ("VIDEO coarse match: VOD t={0:N2}s  (corr={1:N3}, next-best elsewhere={2:N3})" -f $coarseOffset, $best, $second)
    $videoConfident = ($best -gt 0.30 -and $best -gt ($second * 1.5))

    # ---- 2. fine: direct pixel match at the most distinctive moment ----------
    # Anchored on the busiest moment in the first 30s rather than t=0, in case
    # the recording opens on black or a static frame.
    $anchor = 5.0; $bestScore = -1
    for ($i = 0; $i -lt $sigMaster.times.Count; $i++) {
        $t = $sigMaster.times[$i]
        if ($t -gt 2 -and $t -lt 30 -and $sigMaster.scores[$i] -gt $bestScore) {
            $bestScore = $sigMaster.scores[$i]; $anchor = $t
        }
    }
    Log ("Fine pixel match, anchored at master t={0:N2}s ..." -f $anchor)

    $w = 64; $h = 36; $frameBytes = $w * $h
    $refSpan = 0.5; $searchPad = 1.5
    $vodStart = [Math]::Max(0, $coarseOffset + $anchor - $searchPad)
    $vodSpan  = ($searchPad * 2) + $refSpan

    $rfB = Get-RawFrames $Master $anchor   $refSpan "master" $w $h $fps
    $sfB = Get-RawFrames $Vod    $vodStart $vodSpan "vod"    $w $h $fps

    $offset  = $coarseOffset
    $pixDist = -1.0
    $fineUsed = $false
    if ($rfB -and $sfB) {
        $refCount  = [int][Math]::Floor($rfB.Length / $frameBytes)
        $srchCount = [int][Math]::Floor($sfB.Length / $frameBytes)
        if ($refCount -ge 3 -and $srchCount -gt $refCount) {
            $d = 0.0
            $flag = [Sig]::BestFrameMatch($rfB, $sfB, $frameBytes, $refCount, $srchCount, [ref]$d)
            $maxLag = $srchCount - $refCount
            $pixDist = $d
            $matchedVod = $vodStart + ($flag / $fps)
            Log ("VIDEO fine match: master t={0:N2}s = VOD t={1:N3}s" -f $anchor, $matchedVod)
            Log ("  mean pixel difference at the best match: {0:N1} / 255  (low = the two really do show the same picture)" -f $pixDist)

            # The fine pass only searches +/-1.5s around the coarse answer. If
            # the true match lies outside that, the best lag pins to an edge of
            # the window and the "match" is meaningless - so do not adopt it
            # blindly, which is what an earlier version did.
            if ($pixDist -gt 12.0) {
                Log ("  REJECTED: a mean difference of {0:N1}/255 is not a match. Keeping the coarse result." -f $pixDist)
            } elseif ($flag -eq 0 -or $flag -eq $maxLag) {
                Log  "  REJECTED: the best match sits on the edge of the search window, so the"
                Log  "            true match is probably outside it. Keeping the coarse result."
            } else {
                $offset = $matchedVod - $anchor
                $fineUsed = $true
            }
        } else {
            Log "  (not enough frames decoded for the fine pass - keeping the coarse result)"
        }
    } else {
        Log "  (raw frame extraction failed - keeping the coarse result)"
    }

    # ---- 3. independent audio cross-check -----------------------------------
    Log "Audio cross-check (normalised loudness correlation)..."
    $audioOffset = -1.0; $aBest = 0.0; $aSecond = 0.0
    $aStep = 0.1
    $aHz   = [int][Math]::Round(1.0 / $aStep)
    if (-not $a) {
        Log "  the master has no audio stream - skipping the cross-check"
    } else {
        $aRefDur = [Math]::Min(60, $masterDur)
        $aRefSig = Get-AudioEnvelope $Master 0 $aRefDur       $aStep "master"
        $aSrcSig = Get-AudioEnvelope $Vod    0 ($vodDur - 1)  $aStep "vod"
        if ($aRefSig.times.Count -gt 20 -and $aSrcSig.times.Count -gt $aRefSig.times.Count) {
            # Both envelopes are placed on an ABSOLUTE time grid, so a stream
            # whose first sample is not at t=0 no longer biases the answer.
            $aRef = Resample $aRefSig $aRefDur      $aHz
            $aSrc = Resample $aSrcSig ($vodDur - 1) $aHz
            $alag = [Sig]::BestLag($aRef, $aSrc, [int](1.0 * $aHz), [ref]$aBest, [ref]$aSecond)
            if ($alag -ge 0) {
                $audioOffset = $alag / [double]$aHz
                Log ("AUDIO match: VOD t={0:N2}s  (corr={1:N3}, next-best elsewhere={2:N3})" -f $audioOffset, $aBest, $aSecond)
            } else {
                Log "  the VOD's audio envelope is shorter than the reference - skipping"
            }
        } else {
            Log "  audio envelope unavailable - skipping the cross-check"
        }
    }

    # ---- 4. verdict ---------------------------------------------------------
    Log "--------------------------------------------------------------"
    Log ("CHOSEN OFFSET: {0:N3}s of the VOD goes in front of the master" -f $offset)
    Log ("  = {0:N0} min {1:N1} s of recovered footage" -f [Math]::Floor($offset/60), ($offset % 60))
    Log ("  source: {0}" -f $(if ($fineUsed) { "fine pixel match" } else { "coarse motion correlation" }))
    if ($audioOffset -ge 0) {
        $delta = [Math]::Abs($audioOffset - $offset)
        Log ("  audio independently says {0:N2}s -> they differ by {1:N2}s ({2:N1} frames)" -f $audioOffset, $delta, ($delta * $fps))
        if ($delta -lt 0.5) { Log "  => both methods AGREE. High confidence." }
        else {
            Log "  => the methods DISAGREE. Check the verification images before merging."
            Log "     If the pixel difference above is low (< 2/255) the video answer is the"
            Log "     right one; a real audio offset in the VOD can be corrected with"
            Log "     -AudioShift at merge time."
        }
    }
    if (-not $videoConfident) { Log "  WARNING: the video correlation peak is weak - check the images carefully." }
    Log "--------------------------------------------------------------"

    Assert-SaneOffset $offset $vodDur

    # ---- 5. verification stills (VOD LEFT, master RIGHT) --------------------
    Log "Writing side-by-side verification images to merge_work\verify ..."
    $checkPoints = @(0.5, $anchor, [Math]::Min($masterDur - 1, ($vodDur - $offset) * 0.7))
    $n = 0
    foreach ($hd in $checkPoints) {
        $n++
        $tw = $offset + $hd
        if ($tw -lt 0 -or $tw -gt ($vodDur - 0.5)) { continue }
        $name = Join-Path $VerifyDir ("check{0}.jpg" -f $n)
        FF (@("-y", "-hide_banner", "-loglevel", "error") + $TsFix +
            @("-ss", (F $tw), "-i", $Vod, "-ss", (F $hd), "-i", $Master,
              "-filter_complex", "[0:v]scale=600:-2[a];[1:v]scale=600:-2[b];[a][b]hstack=inputs=2",
              "-frames:v", "1", "-q:v", "3", $name)) "verification still $n" | Out-Null
        if (Test-Path $name) { Log ("  check{0}.jpg  (VOD t={1:N2}s | master t={2:N2}s)" -f $n, $tw, $hd) }
    }

    # The join preflight lives in the merge stage, where it can test the REAL
    # opening against the REAL master. Testing surrogate files here is exactly
    # what let the MOV failure slip through.

    # ---- 6. save the result -------------------------------------------------
    @(
        "offset=" + (F $offset)
        "audio_offset=" + (F $audioOffset)
        "video_corr=" + (F $best)
        "pixel_distance=" + (F $pixDist)
        "fps=" + (F $fps)
        "fine_used=" + $(if ($fineUsed) { "1" } else { "0" })
    ) | ForEach-Object { $_ } | Set-Content -LiteralPath $SyncFile -Encoding Ascii

    Log "ANALYSIS DONE. Nothing was modified."
    Log "Next: run 2-seamtest.bat to watch the join before committing to the merge."
    Finish 0
}

# ============================================================================
# STAGE: SEAMTEST
# ============================================================================
if ($Stage -eq "seamtest") {

    Log "=== SEAM TEST ==="
    Require-Inputs
    $offset = Read-Offset

    $masterInfo = Probe $Master
    $vodInfo    = Probe $Vod
    if (-not $masterInfo -or -not $vodInfo) { Log "ERROR: could not probe the inputs."; Finish 1 }
    $v = Get-VideoStream $masterInfo
    $vodDur = [double]$vodInfo.format.duration
    Assert-SaneOffset $offset $vodDur

    # How much to show on each side of the cut, capped by what is actually
    # available: we cannot show more VOD than the recovered opening itself.
    $pre  = [Math]::Min($Pre, $offset)
    $post = $Post
    if ($pre -lt 1) {
        Log ("ERROR: the offset is only {0:N2}s, so there is nothing to show before the cut." -f $offset)
        Finish 1
    }
    $testOut = if ($Out) { $OutFile } else { Join-Path $ExportDir "seam_test.mp4" }
    $tDir = [System.IO.Path]::GetDirectoryName($testOut)
    if ($tDir -and -not (Test-Path -LiteralPath $tDir)) { New-Item -ItemType Directory -Force -Path $tDir | Out-Null }

    Log ("Offset in use: {0:N3}s" -f $offset)
    Log ("Building a {0:N0}s clip: {1:N0}s of VOD, then the cut, then {2:N0}s of the master." -f ($pre + $post), $pre, $post)
    Log ("The cut lands at exactly {0:N0}s into the clip." -f $pre)

    $vw = FI $v.width; $vh = FI $v.height; $rate = $v.r_frame_rate
    $fpre = F $pre; $fpost = F $post

    # Each segment's video and audio are trimmed to exactly the same length.
    # That is not tidiness: the concat FILTER pads whichever of a segment's two
    # streams is shorter, and a VOD's audio track is routinely a few tens of
    # milliseconds shorter than the video for a given window, because the two
    # tracks start at different times. The padding lands exactly on the cut and
    # is audible as a click. Measured on the real job at the default 90s
    # setting: 22.6 ms of digital silence at the seam without these trims,
    # 2.3 ms with them - and the 2.3 ms is quiet content, not a hole.
    #
    # apad before atrim guarantees the audio can actually reach the trim point;
    # atrim alone would leave it short again.
    $fc = "[0:v]scale=${vw}:${vh},fps=$rate,setsar=1,format=yuv420p,trim=0:${fpre},setpts=PTS-STARTPTS[v0];" +
          "[1:v]scale=${vw}:${vh},fps=$rate,setsar=1,format=yuv420p,trim=0:${fpost},setpts=PTS-STARTPTS[v1];" +
          "[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=0:${fpre},asetpts=PTS-STARTPTS[a0];" +
          "[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=0:${fpost},asetpts=PTS-STARTPTS[a1];" +
          "[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]"

    $ok = FF (@("-y", "-hide_banner", "-loglevel", "error") + $TsFix +
              @("-ss", (F ($offset - $pre)), "-t", (F $pre), "-i", $Vod,
                "-ss", "0", "-t", (F $post), "-i", $Master,
                "-filter_complex", $fc, "-map", "[v]", "-map", "[a]",
                "-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
                $testOut)) "seam test clip"

    if ($ok -and (Test-Path -LiteralPath $testOut)) {
        Log ("OK -> {0}  ({1:N0} MB)" -f $testOut, ((Get-Item $testOut).Length / 1MB))
        Log ""
        Log ("WHAT TO LOOK FOR, at {0:N0}s into the clip:" -f $pre)
        Log  "  - the action should flow straight through, with no jump back,"
        Log  "    no skipped moment and no frozen frame"
        Log  "  - the picture will visibly sharpen at the cut: that is normal,"
        Log  "    the first half is the compressed VOD, the second half is your"
        Log  "    clean local capture"
        Log  "  - listen for a word or a sound repeating itself across the cut."
        Log  "    If you hear one, the VOD's own audio is offset against its video:"
        Log  "    re-run the merge with -AudioShift <seconds>."
    } else {
        Log "ERROR: could not build the test clip."
        Finish 1
    }

    Log "DONE."
    Finish 0
}

# ============================================================================
# STAGE: MERGE
# ============================================================================
if ($Stage -eq "merge") {

    Log "=== MERGE ==="
    Log ("Root: {0}" -f $Root)
    Log ("Master: {0}" -f $Master)
    Log ("VOD   : {0}" -f $Vod)
    Log ("Output: {0}" -f $OutFile)
    Require-Inputs
    $offset = Read-Offset

    $masterInfo = Probe $Master
    $vodInfo    = Probe $Vod
    if (-not $masterInfo -or -not $vodInfo) { Log "ERROR: could not probe the inputs."; Finish 1 }
    $masterDur = [double]$masterInfo.format.duration
    $vodDur    = [double]$vodInfo.format.duration
    $v = Get-VideoStream $masterInfo
    $a = Get-AudioStream $masterInfo
    if (-not $v -or -not $a) { Log "ERROR: the master needs both a video and an audio stream."; Finish 1 }
    Assert-SaneOffset $offset $vodDur

    $masterBytes = [double](Get-Item -LiteralPath $Master).Length
    $masterRate  = $masterBytes / $masterDur          # bytes per second
    $vodBytes    = [double](Get-Item -LiteralPath $Vod).Length
    $vodRate     = $vodBytes / $vodDur

    # Refuse to start a 40-minute write that cannot possibly fit. The estimate
    # accounts for the recovered head, not just the master: a fixed 5% margin
    # only happens to cover a short head.
    $outDir = [System.IO.Path]::GetDirectoryName($OutFile)
    if (-not $outDir) { Log "ERROR: could not determine the output directory for $OutFile."; Finish 1 }
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    Warn-SameDrive $OutFile $Master

    # The head is encoded at a higher quality than the VOD, so budget for the
    # master's bitrate rather than the VOD's, which is the conservative choice.
    $headEstimate = $offset * [Math]::Max($masterRate, $vodRate)
    if (-not (Test-FreeSpace $outDir ($masterBytes + $headEstimate + 1GB) "Destination")) {
        Log "Pass a different output path, for example:"
        Log '       3-merge.bat "D:\somewhere\merged.mp4"'
        Log "Nothing was written. Your originals are untouched."
        Finish 1
    }
    if (-not (Test-FreeSpace $WorkDir ($headEstimate + 512MB) "Work folder")) {
        Log "The work folder holds the re-encoded head. Pass -Work <path> to move it."
        Finish 1
    }

    # Full stream inventory. A Blackmagic recorder often adds a timecode (tmcd)
    # data track, and that extra track is what makes the concat demuxer
    # mis-pair streams (CONSTRAINT 5).
    Log "Streams in the master:"
    foreach ($s in ($masterInfo.streams | Sort-Object index)) {
        Log ("  #{0} {1,-8} {2,-12} tag={3}" -f $s.index, $s.codec_type, $s.codec_name, $s.codec_tag_string)
    }

    # ---- 1. the opening itself (video + audio) ------------------------------
    $rawSeg = New-Opening $offset $v $a

    # ---- 2. give the opening the master's stream layout ---------------------
    $segment = Add-MasterStreamLayout $rawSeg $masterInfo

    $list = Join-Path $WorkDir "concat_list.txt"
    Write-ConcatList $list $segment $Master

    # ---- 3. preflight: the exact command, stopped by SIZE not by time -------
    $headBytes = [double](Get-Item -LiteralPath $segment).Length
    if (-not (Invoke-Preflight $list $offset $headBytes $masterRate $OutFile)) {
        Log "PREFLIGHT FAILED - stopping before writing the whole file."
        Log "Your originals are untouched. See the log above, and try 4-stripmerge.bat."
        Finish 1
    }

    Log "Joining by stream copy - the master is copied byte for byte, never re-encoded."
    if (-not (Invoke-FinalJoin $list $OutFile "final join")) { Finish 1 }

    $o = Probe $OutFile
    Log ("SUCCESS -> {0}" -f $OutFile)
    if ($o) { Log ("Duration {0:N1}s (expected ~{1:N1}s)" -f [double]$o.format.duration, ($offset + $masterDur)) }

    Log "Checking the seam for decode errors..."
    $global:LASTEXITCODE = 0
    # CONSTRAINT 4 -- rawvideo sink, not "-f null".
    $errs = & $ffmpeg -hide_banner -v error -ss (F ([Math]::Max(0, $offset - 3))) -t 8 -i $OutFile -map 0:v:0 -f rawvideo -pix_fmt gray -y NUL 2>&1 | Out-String
    if ([string]::IsNullOrWhiteSpace($errs.Trim())) { Log "  The seam decodes cleanly." }
    else { Log ("  Seam warnings: " + (($errs.Trim() -split "`r?`n" | Select-Object -First 4) -join "  //  ")) }

    $k = 0
    foreach ($d in @(-0.25, 0.0, 0.25)) {
        $k++
        $t = $offset + $d
        if ($t -lt 0) { continue }
        $img = Join-Path $VerifyDir ("seam{0}.jpg" -f $k)
        FF @("-y", "-hide_banner", "-loglevel", "error", "-ss", (F $t), "-i", $OutFile,
             "-frames:v", "1", "-q:v", "3", $img) "seam still $k" | Out-Null
    }
    Log "Seam stills written to merge_work\verify\ (seam1/2/3.jpg)."
    Log "DONE."
    Finish 0
}

# ============================================================================
# STAGE: STRIPMERGE -- fallback route.
# CONSTRAINT 6 -- do NOT "fix" the stream-layout problem by switching the
# output to Matroska. MKV has no equivalent check: it would not error, it would
# silently write timecode bytes into the audio track. This stage is the
# legitimate fallback - it removes the timecode track from a copy of the master
# so both files are plain video+audio, at the cost of one extra full pass.
# ============================================================================
if ($Stage -eq "stripmerge") {

    Log "=== STRIP + MERGE (fallback route) ==="
    Require-Inputs
    $offset = Read-Offset

    $masterInfo = Probe $Master
    $vodInfo    = Probe $Vod
    if (-not $masterInfo -or -not $vodInfo) { Log "ERROR: could not probe the inputs."; Finish 1 }
    $masterDur = [double]$masterInfo.format.duration
    $vodDur    = [double]$vodInfo.format.duration
    $v = Get-VideoStream $masterInfo
    $a = Get-AudioStream $masterInfo
    if (-not $v -or -not $a) { Log "ERROR: the master needs both a video and an audio stream."; Finish 1 }
    Assert-SaneOffset $offset $vodDur

    $masterBytes = [double](Get-Item -LiteralPath $Master).Length
    $masterRate  = $masterBytes / $masterDur
    $vodRate     = [double](Get-Item -LiteralPath $Vod).Length / $vodDur
    $headEstimate = $offset * [Math]::Max($masterRate, $vodRate)

    # The timecode-free intermediate defaults to sitting next to the output,
    # never to a hardcoded drive letter.
    $stripped = if ($Strip) { Resolve-UserPath $Strip } else {
        Join-Path ([System.IO.Path]::GetDirectoryName($OutFile)) `
                  ([System.IO.Path]::GetFileNameWithoutExtension($Master) + "_noTC" + [System.IO.Path]::GetExtension($Master))
    }
    $strippedDir = [System.IO.Path]::GetDirectoryName($stripped)
    $outDir      = [System.IO.Path]::GetDirectoryName($OutFile)
    if (-not (Test-Path -LiteralPath $outDir))      { New-Item -ItemType Directory -Force -Path $outDir      | Out-Null }
    if (-not (Test-Path -LiteralPath $strippedDir)) { New-Item -ItemType Directory -Force -Path $strippedDir | Out-Null }

    Log ("Intermediate (timecode-free copy): {0}" -f $stripped)
    Log ("Final output                     : {0}" -f $OutFile)
    Log "This route writes the master twice. Budget one full pass extra."
    Warn-SameDrive $OutFile $Master

    # Both files exist at the same time, so if they share a drive it has to
    # hold both.
    $sameDrive = ([System.IO.Path]::GetPathRoot($stripped) -eq [System.IO.Path]::GetPathRoot($OutFile))
    if ($sameDrive) {
        if (-not (Test-FreeSpace $outDir (($masterBytes * 2) + $headEstimate + 1GB) "Destination (holds both files)")) {
            Log "Pass -Strip <path on another drive> or -Out <path on another drive>."
            Finish 1
        }
    } else {
        if (-not (Test-FreeSpace $strippedDir ($masterBytes + 1GB) "Intermediate")) { Finish 1 }
        if (-not (Test-FreeSpace $outDir ($masterBytes + $headEstimate + 1GB) "Destination")) { Finish 1 }
    }
    if (-not (Test-FreeSpace $WorkDir ($headEstimate + 512MB) "Work folder")) { Finish 1 }

    # Step 0: the opening, exactly as in the merge stage.
    $rawSeg = New-Opening $offset $v $a

    # Step 1: the master without its timecode track. Stream copy, so lossless.
    Log ("Step 1/2: copying the master without its timecode track -> {0}" -f $stripped)
    Log  "  (stream copy, nothing is re-encoded; this is one full pass)"
    $strippedPart = Get-SiblingPath $stripped "part"
    Remove-Item -LiteralPath $strippedPart -Force -ErrorAction SilentlyContinue
    if (-not (FF @("-y", "-hide_banner", "-loglevel", "warning", "-nostats",
                   "-i", $Master, "-map", "0:v:0", "-map", "0:a:0", "-c", "copy",
                   $strippedPart) "strip timecode")) {
        Remove-Item -LiteralPath $strippedPart -Force -ErrorAction SilentlyContinue
        Log "ERROR: the strip pass failed. The partial copy was deleted. Originals untouched."
        Finish 1
    }
    Remove-Item -LiteralPath $stripped -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $strippedPart -Destination $stripped -Force
    Log ("  done: {0:N1} GB" -f ((Get-Item $stripped).Length / 1GB))

    # Step 2: both files are now video+audio only, so the indices line up.
    $list = Join-Path $WorkDir "concat_list.txt"
    Write-ConcatList $list $rawSeg $stripped

    $headBytes = [double](Get-Item -LiteralPath $rawSeg).Length
    if (-not (Invoke-Preflight $list $offset $headBytes $masterRate $OutFile)) {
        Log "PREFLIGHT FAILED - stopping before writing the whole file."
        Log ("The intermediate copy {0} was kept; delete it yourself once you are done." -f $stripped)
        Finish 1
    }

    Log ("Step 2/2: writing the final file -> {0}" -f $OutFile)
    if (-not (Invoke-FinalJoin $list $OutFile "final join")) {
        Log ("The intermediate copy {0} was kept." -f $stripped)
        Finish 1
    }

    $o = Probe $OutFile
    Log ("SUCCESS -> {0}" -f $OutFile)
    if ($o) { Log ("Duration {0:N1}s (expected ~{1:N1}s)" -f [double]$o.format.duration, ($offset + $masterDur)) }
    Log ("You can delete the intermediate copy {0} once you have checked the result." -f $stripped)
    Log "DONE."
    Finish 0
}

# ============================================================================
# STAGE: DOCTOR -- everything needed to diagnose a failure, in one place.
# ============================================================================
if ($Stage -eq "doctor") {

    Log "=== DOCTOR ==="
    Log "vodpatch, Copyright (C) 2026 Deployer. GNU GPL v3 or later,"
    Log "with ABSOLUTELY NO WARRANTY. See the LICENSE file for details."
    Log ""
    Log ("ffmpeg : {0}" -f $ffmpeg)
    Log ("ffprobe: {0}" -f $ffprobe)
    $ver = (& $ffmpeg -hide_banner -version 2>&1 | Select-Object -First 1)
    Log ("version: {0}" -f $ver)
    $cfg = (& $ffmpeg -hide_banner -version 2>&1 | Out-String)
    $hasGpl = $cfg -match '--enable-gpl'
    $hasX264 = $cfg -match '--enable-libx264'
    Log ("build  : --enable-gpl={0}  --enable-libx264={1}" -f $hasGpl, $hasX264)
    if (-not $hasX264) {
        Log "  WARNING: no libx264 in this build - the merge stage cannot encode the opening."
        Log "           libx264 is GPL-licensed; you need a GPL-enabled ffmpeg build."
    }
    Log ("PowerShell: {0}   culture: {1}" -f $PSVersionTable.PSVersion, (Get-Culture).Name)
    Log ("Invariant formatting check: 147.5 -> '{0}' (must be '147.5', never '147,5')" -f (F 147.5))
    Log ""
    Log ("Root  : {0}" -f $Root)
    Log ("Master: {0}   {1}" -f $Master, $(if (Test-Path -LiteralPath $Master) { "present" } else { "MISSING" }))
    Log ("VOD   : {0}   {1}" -f $Vod,    $(if (Test-Path -LiteralPath $Vod)    { "present" } else { "MISSING" }))
    Log ("Work  : {0}" -f $WorkDir)
    Log ("Out   : {0}" -f $OutFile)

    foreach ($pair in @(@("Root", $Root), @("Work", $WorkDir), @("Out", [System.IO.Path]::GetDirectoryName($OutFile)))) {
        $f = Get-FreeBytes $pair[1]
        if ($f -ge 0) { Log ("Free at {0,-5}: {1,8:N1} GB  ({2})" -f $pair[0], ($f/1GB), $pair[1]) }
        else          { Log ("Free at {0,-5}: unknown        ({1})" -f $pair[0], $pair[1]) }
    }

    Require-Inputs
    foreach ($pair in @(@("master", $Master), @("VOD", $Vod))) {
        $info = Probe $pair[1]
        if (-not $info) { Log ("{0}: does not probe" -f $pair[0]); continue }
        Log ("{0}: {1:N1}s, {2:N2} GB" -f $pair[0], [double]$info.format.duration, ((Get-Item -LiteralPath $pair[1]).Length/1GB))
        foreach ($s in ($info.streams | Sort-Object index)) {
            Log ("   #{0} {1,-6} {2,-12} tag={3,-6} start={4,-10} dur={5}" -f `
                 $s.index, $s.codec_type, $s.codec_name, $s.codec_tag_string, $s.start_time, $s.duration)
        }
    }

    if (Test-Path -LiteralPath $SyncFile) {
        Log "Analysis result:"
        foreach ($l in (Get-Content $SyncFile)) { Log ("   {0}" -f $l) }
    } else {
        Log "No analysis result yet (run 1-analyze.bat)."
    }

    $seg = Join-Path $WorkDir "opening.mp4"
    if (Test-Path -LiteralPath $seg) {
        $si = Probe $seg
        Log ("Cached opening: {0:N0} MB" -f ((Get-Item $seg).Length/1MB))
        if ($si) {
            foreach ($s in ($si.streams | Sort-Object index)) {
                Log ("   #{0} {1,-6} {2,-12} start={3,-10} dur={4}" -f $s.index, $s.codec_type, $s.codec_name, $s.start_time, $s.duration)
            }
        }
        if (Test-Path -LiteralPath $StampFile) { Log ("   built from: {0}" -f (Get-Content -Raw $StampFile).Trim()) }
    } else {
        Log "No cached opening."
    }

    Log ""
    Log "Doctor finished. Attach this log when reporting a problem."
    Finish 0
}

# ============================================================================
# STAGE: MENU - the front door.
#
# Each action re-invokes this script as a child process with the matching
# -Stage. That is deliberate: the stages below are the code that has actually
# been validated against real footage, and running them unchanged in their own
# process means a stage that calls Finish 1 cannot take the menu down with it.
# The cost is one extra powershell.exe per action, which is about a second.
# ============================================================================
if ($Stage -eq "menu") {

    $ScriptPath = $PSCommandPath
    if (-not $ScriptPath) { $ScriptPath = $MyInvocation.MyCommand.Path }

    $PsExe = Join-Path $PSHOME "powershell.exe"
    if (-not (Test-Path $PsExe)) { $PsExe = "powershell.exe" }

    # A trailing backslash immediately before a closing quote escapes the quote
    # on a Windows command line, so "-Root F:\" would arrive as: -Root  F:"
    function ArgPath([string]$p) { return $p.TrimEnd('\') }

    function Invoke-Stage([string]$name, [string[]]$extra) {
        $callArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath,
                      "-Stage",  $name,
                      "-Root",   (ArgPath $Root),
                      "-Vod",    (ArgPath $Vod),
                      "-Master", (ArgPath $Master),
                      "-Work",   (ArgPath $WorkDir)) + $extra
        Write-Host ""
        & $PsExe @callArgs
        Write-Host ""
        Write-Host "  -- press Enter to return to the menu --" -ForegroundColor DarkGray
        [void](Read-Host)
    }

    # --- one-time facts ------------------------------------------------------
    $mInfo = $null; $vInfo = $null
    $mBytes = 0.0; $mDur = 0.0; $vDur = 0.0; $mRate = 0.0
    $autoPicked = $false
    if (-not ((Test-Path -LiteralPath $Master) -and (Test-Path -LiteralPath $Vod))) {
        $autoPicked = Find-Sources          # unzipped somewhere with the footage
    }
    $inputsOk = (Test-Path -LiteralPath $Master) -and (Test-Path -LiteralPath $Vod)
    if ($inputsOk) {
        $mInfo = Probe $Master
        $vInfo = Probe $Vod
        if ($mInfo) {
            $mBytes = [double](Get-Item -LiteralPath $Master).Length
            $mDur   = [double]$mInfo.format.duration
            if ($mDur -gt 0) { $mRate = $mBytes / $mDur }
        }
        if ($vInfo) { $vDur = [double]$vInfo.format.duration }
    }

    $dest = $OutFile

    function Get-State() {
        $s = @{ offset = $null; audio = $null; pix = $null; agree = $false; seam = $null }
        if (Test-Path -LiteralPath $SyncFile) {
            $cfg = @{}
            foreach ($line in (Get-Content $SyncFile)) {
                if ($line -match '^([a-z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] }
            }
            $inv = [System.Globalization.CultureInfo]::InvariantCulture
            $tmp = 0.0
            foreach ($k in @("offset", "audio_offset", "pixel_distance")) {
                if ($cfg.ContainsKey($k) -and
                    [double]::TryParse($cfg[$k], [System.Globalization.NumberStyles]::Float, $inv, [ref]$tmp)) {
                    switch ($k) {
                        "offset"         { $s.offset = $tmp }
                        "audio_offset"   { $s.audio  = $tmp }
                        "pixel_distance" { $s.pix    = $tmp }
                    }
                }
            }
            if ($null -ne $s.offset -and $null -ne $s.audio -and $s.audio -ge 0) {
                $s.agree = ([Math]::Abs($s.audio - $s.offset) -lt 0.5)
            }
        }
        $seamFile = Join-Path $ExportDir "seam_test.mp4"
        if (Test-Path -LiteralPath $seamFile) { $s.seam = (Get-Item -LiteralPath $seamFile).LastWriteTime }
        return $s
    }

    function Show-Age([datetime]$t) {
        $m = [int]((Get-Date) - $t).TotalMinutes
        if ($m -lt 1)    { return "just now" }
        if ($m -lt 60)   { return ("{0} min ago" -f $m) }
        if ($m -lt 1440) { return ("{0} h ago" -f [int]($m/60)) }
        return $t.ToString("yyyy-MM-dd HH:mm")
    }

    $empties = 0
    while ($true) {
        $st = Get-State

        # how much the merge would need at the destination
        $need = 0.0
        if ($mBytes -gt 0) {
            $head = if ($null -ne $st.offset) { $st.offset * $mRate } else { $mBytes * 0.05 }
            $need = $mBytes + $head + 1GB
        }
        $free = Get-FreeBytes $dest
        $spaceOk = ($free -lt 0) -or ($free -ge $need)

        Clear-Host
        Write-Host ""
        Write-Host "  vodpatch" -ForegroundColor Cyan -NoNewline
        Write-Host "                                          GPL v3" -ForegroundColor DarkGray
        Write-Host "  ----------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host ("  Folder   {0}" -f $Root)

        if (-not $inputsOk) {
            Write-Host ""
            Write-Host "  No recordings found. Press [F] to choose them." -ForegroundColor Yellow
            Write-Host ("    looked in  {0}" -f $Root) -ForegroundColor DarkGray
            $found = @(Get-VideoFiles $Root)
            if ($found.Count -eq 0) {
                Write-Host "    there are no video files there at all" -ForegroundColor DarkGray
            } elseif ($found.Count -eq 1) {
                Write-Host ("    only one video file there ({0}) - two are needed" -f $found[0].Name) -ForegroundColor DarkGray
            } else {
                Write-Host "    could not tell which two to use - press [F] to say which" -ForegroundColor DarkGray
            }
            Write-Host "    needed: the local recording, and the stream VOD of the same session" -ForegroundColor DarkGray
        } else {
            Write-Host ("  VOD      {0,-22} {1,9:N1} s  {2,6:N2} GB" -f `
                        [System.IO.Path]::GetFileName($Vod), $vDur, ((Get-Item -LiteralPath $Vod).Length/1GB))
            Write-Host ("  Master   {0,-22} {1,9:N1} s  {2,6:N2} GB" -f `
                        [System.IO.Path]::GetFileName($Master), $mDur, ($mBytes/1GB))
            if ($mInfo) {
                $layout = (($mInfo.streams | Sort-Object index | ForEach-Object { $_.codec_type }) -join ", ")
                Write-Host ("           streams: {0}" -f $layout) -ForegroundColor DarkGray
            }
            if ($autoPicked) {
                Write-Host "           picked by size - press [F] if that is the wrong way round" -ForegroundColor Yellow
            }
        }

        Write-Host ""
        Write-Host ("  Output   {0}" -f $dest)
        if ($free -lt 0) {
            Write-Host "           free space unknown for this path" -ForegroundColor Yellow
        } elseif (-not $inputsOk) {
            # No recordings yet, so there is no requirement to compare against.
            Write-Host ("           {0:N1} GB free" -f ($free/1GB)) -ForegroundColor DarkGray
        } elseif ($spaceOk) {
            Write-Host ("           {0:N1} GB free, needs about {1:N1} GB" -f ($free/1GB), ($need/1GB)) -ForegroundColor DarkGray
        } else {
            Write-Host ("           {0:N1} GB free - NOT ENOUGH, needs about {1:N1} GB" -f ($free/1GB), ($need/1GB)) -ForegroundColor Red
        }
        # Only meaningful once we actually know where the recordings are.
        if ($inputsOk) {
            try {
                if ([System.IO.Path]::GetPathRoot($dest) -eq [System.IO.Path]::GetPathRoot($Master)) {
                    Write-Host "           same drive as the recordings - this will be very slow" -ForegroundColor Yellow
                }
            } catch { }
        }

        Write-Host ""
        # [1] analyze
        if ($null -eq $st.offset) {
            Write-Host "  [1] Analyze        " -NoNewline; Write-Host "not run" -ForegroundColor Yellow
        } else {
            $note = if ($st.agree) { "methods agree" } else { "METHODS DISAGREE - check the images" }
            $col  = if ($st.agree) { "Green" } else { "Yellow" }
            Write-Host "  [1] Analyze        " -NoNewline
            Write-Host ("offset {0:N3} s, {1}" -f $st.offset, $note) -ForegroundColor $col
        }
        # [2] seam test
        Write-Host "  [2] Seam test      " -NoNewline
        if ($null -eq $st.seam) { Write-Host "not run" -ForegroundColor Yellow }
        else { Write-Host ("seam_test.mp4, {0}" -f (Show-Age $st.seam)) -ForegroundColor Green }
        # [3] merge
        Write-Host "  [3] Merge          " -NoNewline
        if (-not $inputsOk)         { Write-Host "choose the source files first - press [F]" -ForegroundColor DarkGray }
        elseif ($null -eq $st.offset) { Write-Host "run the analysis first" -ForegroundColor DarkGray }
        elseif (-not $spaceOk)      { Write-Host "blocked: not enough space at the destination" -ForegroundColor Red }
        elseif ($null -eq $st.seam) { Write-Host "ready (watching the seam test first is wise)" -ForegroundColor Green }
        else                        { Write-Host "ready" -ForegroundColor Green }

        Write-Host "  [4] Merge - fallback route (strip the timecode track)"
        Write-Host "  [5] Doctor - diagnostics for a bug report"
        Write-Host "  [6] Clean the working files"
        Write-Host ""
        Write-Host "  [F] Choose the source files"
        Write-Host "  [D] Change the output destination"
        Write-Host "  [Q] Quit"
        Write-Host ""
        Write-Host -NoNewline "  Choice: "

        $choice = $null
        try { $choice = Read-Host } catch { $choice = $null }
        if ([string]::IsNullOrWhiteSpace($choice)) {
            $empties++
            # Nothing on stdin: this is not an interactive console (someone
            # piped input, or ran the script from a scheduler). Do not spin.
            if ($empties -ge 3) {
                Write-Host ""
                Write-Host "  No input - exiting. For non-interactive use, pass a stage:" -ForegroundColor DarkGray
                Write-Host "    vodpatch.bat analyze" -ForegroundColor DarkGray
                Write-Host '    vodpatch.bat merge "D:\out\full.mp4"' -ForegroundColor DarkGray
                Finish 0
            }
            continue
        }
        $empties = 0

        switch ($choice.Trim().ToUpper()) {
            "1" { Invoke-Stage "analyze" @() }
            "2" {
                Write-Host ""
                Write-Host -NoNewline "  Seconds of VOD before the cut [90]: "
                $p1 = Read-Host
                Write-Host -NoNewline "  Seconds of master after it    [90]: "
                $p2 = Read-Host
                $ex = @()
                if ($p1 -and ($p1 -as [double])) { $ex += @("-Pre",  (F ([double]$p1))) }
                if ($p2 -and ($p2 -as [double])) { $ex += @("-Post", (F ([double]$p2))) }
                Invoke-Stage "seamtest" $ex
            }
            "3" {
                if (-not $spaceOk) {
                    Write-Host ""
                    Write-Host "  The destination does not have room. Press [D] to change it first." -ForegroundColor Red
                    Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                    [void](Read-Host)
                } else {
                    Invoke-Stage "merge" @("-Out", $dest)
                }
            }
            "4" { Invoke-Stage "stripmerge" @("-Out", $dest) }
            "5" { Invoke-Stage "doctor" @("-Out", $dest) }
            "6" {
                Write-Host ""
                Write-Host "  This removes the re-encoded head, the concat list and the analysis"
                Write-Host "  temporaries. It KEEPS sync_result.txt and merge_work\verify\."
                Write-Host -NoNewline "  Type YES to confirm: "
                if ((Read-Host) -eq "YES") {
                    foreach ($n in @("opening.mp4", "opening_tc.mov", "opening_stamp.txt",
                                     "concat_list.txt", "progress.txt", "probe_raw.mp4", "probe_tc.mov")) {
                        Remove-Item -LiteralPath (Join-Path $WorkDir $n) -Force -ErrorAction SilentlyContinue
                    }
                    foreach ($g in @("scenes_*.txt", "scenes2_*.txt", "env_*.txt", "frames_*.gray", "*.part.*")) {
                        Get-ChildItem -LiteralPath $WorkDir -Filter $g -File -ErrorAction SilentlyContinue |
                            Remove-Item -Force -ErrorAction SilentlyContinue
                    }
                    Write-Host "  Done." -ForegroundColor Green
                } else {
                    Write-Host "  Cancelled."
                }
                Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                [void](Read-Host)
            }
            "F" {
                Write-Host ""
                Write-Host "  Paste a path, or drag the file into this window and press Enter."
                Write-Host "  Leave blank to keep the current one." -ForegroundColor DarkGray

                $near = Get-VideoFiles (Split-Path -Parent $Master)
                if (-not $near) { $near = Get-VideoFiles $Root }
                if ($near) {
                    Write-Host ""
                    Write-Host "  Video files found nearby:" -ForegroundColor DarkGray
                    $i = 0
                    foreach ($f in ($near | Select-Object -First 9)) {
                        $i++
                        Write-Host ("    {0}) {1,-40} {2,8:N2} GB" -f $i, $f.Name, ($f.Length/1GB)) -ForegroundColor DarkGray
                    }
                    Write-Host "  Type a number from that list, or a full path." -ForegroundColor DarkGray
                }

                # Accepts a list number, a quoted path (what drag-and-drop
                # produces), or a bare path relative to where you launched.
                function Resolve-Pick([string]$raw, $list) {
                    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
                    $raw = $raw.Trim().Trim('"')
                    $n = 0
                    if ([int]::TryParse($raw, [ref]$n) -and $list -and $n -ge 1 -and $n -le $list.Count) {
                        return $list[$n - 1].FullName
                    }
                    if (-not [System.IO.Path]::IsPathRooted($raw)) { $raw = Join-Path $StartCwd $raw }
                    try { return [System.IO.Path]::GetFullPath($raw) } catch { return $null }
                }

                Write-Host ""
                Write-Host ("  Master (the good local recording) [{0}]" -f [System.IO.Path]::GetFileName($Master))
                Write-Host -NoNewline "    > "
                $pick = Resolve-Pick (Read-Host) $near
                if ($pick) {
                    if (Test-Path -LiteralPath $pick -PathType Leaf) { $Master = $pick }
                    else { Write-Host "    not a file: $pick" -ForegroundColor Red }
                }

                Write-Host ("  VOD (the stream recording) [{0}]" -f [System.IO.Path]::GetFileName($Vod))
                Write-Host -NoNewline "    > "
                $pick = Resolve-Pick (Read-Host) $near
                if ($pick) {
                    if (Test-Path -LiteralPath $pick -PathType Leaf) { $Vod = $pick }
                    else { Write-Host "    not a file: $pick" -ForegroundColor Red }
                }

                # Re-read everything the header shows, and follow the sources:
                # the work folder and the default output belong next to the
                # master, not next to wherever the tool was unzipped.
                $inputsOk = (Test-Path -LiteralPath $Master) -and (Test-Path -LiteralPath $Vod)
                if ($inputsOk) {
                    $mInfo = Probe $Master
                    $vInfo = Probe $Vod
                    $mBytes = [double](Get-Item -LiteralPath $Master).Length
                    $mDur = 0.0; $mRate = 0.0; $vDur = 0.0
                    if ($mInfo) {
                        $mDur = [double]$mInfo.format.duration
                        if ($mDur -gt 0) { $mRate = $mBytes / $mDur }
                    }
                    if ($vInfo) { $vDur = [double]$vInfo.format.duration }

                    $mDir = Split-Path -Parent $Master
                    if ($mDir -and (Test-UsableWorkDir (Join-Path $mDir "merge_work"))) {
                        $WorkDir   = Join-Path $mDir "merge_work"
                        $VerifyDir = Join-Path $WorkDir "verify"
                        $SyncFile  = Join-Path $WorkDir "sync_result.txt"
                        $StampFile = Join-Path $WorkDir "opening_stamp.txt"
                        New-Item -ItemType Directory -Force -Path $VerifyDir | Out-Null
                        Write-Host ("  Work folder is now {0}" -f $WorkDir) -ForegroundColor DarkGray
                    }
                }
                Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                [void](Read-Host)
            }
            "D" {
                Write-Host ""
                Write-Host "  Give a full path on a drive OTHER than the master's."
                Write-Host ("  Current: {0}" -f $dest) -ForegroundColor DarkGray
                Write-Host -NoNewline "  New path (Enter to keep): "
                $np = Read-Host
                if ($np) {
                    $np = $np.Trim().Trim('"')
                    if (-not [System.IO.Path]::IsPathRooted($np)) { $np = Join-Path $StartCwd $np }
                    try {
                        $resolved = [System.IO.Path]::GetFullPath($np)
                        if ([System.IO.Path]::GetExtension($resolved) -eq "") {
                            $resolved = Join-Path $resolved "full_recording.mp4"
                        }
                        $dest = $resolved
                    } catch {
                        Write-Host "  That path cannot be used." -ForegroundColor Red
                        Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                        [void](Read-Host)
                    }
                }
            }
            "Q" { Finish 0 }
            default { }
        }
    }
}

Log "Unknown stage '$Stage'."
Finish 1
