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

    # CONSTRAINT 11 -- the four numeric parameters are read as TEXT and parsed
    # by ConvertTo-Seconds below. Declared [double], PowerShell parses them with
    # the invariant culture, where a comma is a THOUSANDS separator. On a French
    # Windows, where a comma is the natural decimal mark, that silently turns
    #     -AudioShift -0,25  into  -25        (measured)
    #     -Offset 12,5       into  125        (measured; passes the sanity check)
    #     -Offset 111,467    into  111467     (measured)
    # The aliases keep the command line unchanged (-Offset, -AudioShift, -Pre,
    # -Post). The variables must NOT be named $Offset etc.: PowerShell names are
    # case-insensitive, so the stages' "$offset = Read-Offset" would then write
    # into the typed parameter.
    [Alias("Pre")][string]$PreText               = "",  # seamtest: seconds of VOD before the cut (5)
    [Alias("Post")][string]$PostText             = "",  # seamtest: seconds of master after it (5)
    [Alias("AudioShift")][string]$AudioShiftText = "",  # shift the opening's audio against its video,
                                                        #   seconds; > 0 delays, < 0 advances
    [Alias("Offset")][string]$OffsetText         = "",  # skip analysis, use this offset
    [switch]$Force                                      # ignore any cached opening
)

# CONSTRAINT 1 -- deliberately NOT "Stop".
# With $ErrorActionPreference = "Stop", PowerShell turns every line ffmpeg
# writes to stderr into a fatal terminating error and kills the script, even
# for harmless warnings. Every ffmpeg call goes through the FF wrapper below,
# which checks $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"
$ProgressPreference    = "SilentlyContinue"

# ProviderPath, not Path: launched from a PowerShell drive of another name,
# .Path is "Name:\..." and GetFullPath rejects it.
$StartCwd = (Get-Location).ProviderPath

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

function Resolve-UserPath([string]$p) {
    # Resolve a user-supplied path against the directory the user launched
    # from, NOT against the work directory we Push-Location into below. A bare
    # "merged.mp4" must not quietly land inside merge_work on the source card.
    if (-not $p) { return "" }
    if (-not [System.IO.Path]::IsPathRooted($p)) { $p = Join-Path $StartCwd $p }
    return [System.IO.Path]::GetFullPath($p)
}

# The card gets a different drive letter on every machine it is plugged into,
# so derive the root from where this script actually lives. A typed -Root is
# made absolute like every other path: a relative one ("-Root .") used to be
# re-read from inside merge_work after the Push-Location below, so the analysis
# looked for its own files in merge_work\merge_work and reported NO MATCH.
# GetFullPath throws on a mangled path (-Root "F:\" typed in cmd arrives as
# F:"), which then stays as typed and fails visibly later, as before.
if ($Root) { try { $Root = Resolve-UserPath $Root } catch { } }
else { $Root = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path } }
if (-not $Root.EndsWith("\")) { $Root += "\" }

# Whether the user named the files. A path the user TYPED is shown back in any
# error about it; the built-in fallback names never are - they mean nothing to
# anyone but the tool's first user, and the folder scan is what matters.
$VodGiven    = -not [string]::IsNullOrWhiteSpace($Vod)
$MasterGiven = -not [string]::IsNullOrWhiteSpace($Master)
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

# Display helpers, invariant on purpose: an offset printed as "111,467" on a
# French Windows is one the user will type straight back in.
function F2($x) {
    $d = [double]$x
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return "n/a" }
    return $d.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)
}
function F3($x) {
    $d = [double]$x
    if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return "n/a" }
    return $d.ToString("0.000", [System.Globalization.CultureInfo]::InvariantCulture)
}

# CONSTRAINT 11 (continued) -- parse a number of seconds typed by a human.
# Accepts "111.467" and "111,467" alike, and nothing else: no thousands
# separators, no exponents, no spaces inside. Returns $null when it is not a
# plain number, so the caller can say so instead of guessing.
function ConvertTo-Seconds([string]$s, [switch]$AllowNegative) {
    if ($null -eq $s) { return $null }
    $t = $s.Trim()
    $pattern = if ($AllowNegative) { '^-?[0-9]+([.,][0-9]+)?$' } else { '^[0-9]+([.,][0-9]+)?$' }
    if ($t -notmatch $pattern) { return $null }
    $x = 0.0
    $styles = [System.Globalization.NumberStyles]::AllowDecimalPoint -bor
              [System.Globalization.NumberStyles]::AllowLeadingSign
    if (-not [double]::TryParse($t.Replace(',', '.'), $styles,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $null }
    return $x
}

function Get-NumberParam([string]$text, [double]$default, [string]$name, [switch]$AllowNegative) {
    if ([string]::IsNullOrWhiteSpace($text)) { return $default }
    $v = ConvertTo-Seconds $text -AllowNegative:$AllowNegative
    if ($null -eq $v) {
        # No "or 12,5" here: this only fails with a comma when the script is called
        # from a PowerShell prompt, where 12,5 is parsed as a LIST before it arrives.
        # From vodpatch.bat, cmd.exe or the menu, a comma works.
        Log ("ERROR: -{0} '{1}' is not a number of seconds. Write it like 12.5" -f $name, $text)
        Finish 1
    }
    return $v
}
$Pre        = Get-NumberParam $PreText        5 "Pre"
$Post       = Get-NumberParam $PostText       5 "Post"
$AudioShift = Get-NumberParam $AudioShiftText 0  "AudioShift" -AllowNegative

$ScriptSelf = $PSCommandPath

# The analysis writes key=value lines; everything that reads them goes through here.
function Read-SyncFile() {
    $cfg = @{}
    if (Test-Path -LiteralPath $SyncFile) {
        foreach ($line in (Get-Content -LiteralPath $SyncFile)) {
            if ($line -match '^([a-z_]+)=(.*)$') { $cfg[$Matches[1]] = $Matches[2] }
        }
    }
    return $cfg
}

function Get-StatusText([string]$st) {
    switch ($st) {
        "confirmed"       { return "confirmed by picture and sound" }
        "video_only"      { return "confirmed by picture" }
        "conflict"        { return "picture and sound disagree" }
        "ambiguous"       { return "the opening matches in more than one place" }
        "unverified"      { return "the picture matched at one moment only" }
        "audio_only"      { return "only the sound matched" }
        "nothing_missing" { return "nothing is missing - the master starts first" }
        "none"            { return "no match at all" }
        "other_files"     { return "computed for other files" }
    }
    return "made by an older version"
}

# The verdict as it applies to the files selected NOW. Everything that decides
# something from sync_result.txt goes through here - the menu, the seam test's
# warning and the merge gate - so they can never disagree. A result without a
# status line comes from the old detector ("legacy"); one whose recorded file
# sizes differ from the current files was computed for other files. Either is
# treated as unconfirmed everywhere, not only at the merge gate.
function Get-EffectiveStatus($cfg) {
    $st = $cfg["status"]
    if (-not $st) { return "legacy" }
    if ((Test-Path -LiteralPath $Master) -and (Test-Path -LiteralPath $Vod)) {
        if ($cfg["master_size"] -ne (FI (Get-Item -LiteralPath $Master).Length) -or
            $cfg["vod_size"]    -ne (FI (Get-Item -LiteralPath $Vod).Length)) { return "other_files" }
    }
    return $st
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

# CONSTRAINT 14 -- every piece of a stream-copy join must count time in the
# SAME units (time base). The concat demuxer does not reconcile them: an
# opening whose video counted in 1/15360 s (what x264 picks by default at an
# integer 60 fps) joined to a master counting in 1/60000 s gave a file whose
# video track claimed 40 691 s instead of 10 417 s - 60000/15360 = 3.906x too
# long, playing in slow motion against the audio and unusable to scrub. At
# 59.94 fps x264's default happens to be 1/60000, which is why a 59.94 master
# never showed it. The opening is therefore encoded with the master's video
# timescale (New-Opening), and Assert-SameClock checks it before any join.
function Get-Timescale($stream) {
    if (-not $stream -or -not $stream.time_base) { return 0 }
    $p = ([string]$stream.time_base) -split '/'
    $n = 0L; $d = 0L
    if ($p.Count -eq 2 -and [long]::TryParse($p[0], [ref]$n) -and [long]::TryParse($p[1], [ref]$d) -and
        $n -eq 1 -and $d -gt 0) { return $d }
    return 0
}

function Assert-SameClock([string]$segPath, $masterInfo) {
    $si = Probe $segPath
    if (-not $si) { Log "ERROR: the recovered opening does not probe."; Finish 1 }
    foreach ($kind in @("video", "audio")) {
        $ms = $masterInfo.streams | Where-Object { $_.codec_type -eq $kind } | Select-Object -First 1
        $ss = $si.streams         | Where-Object { $_.codec_type -eq $kind } | Select-Object -First 1
        if ($ms -and $ss -and ([string]$ms.time_base -ne [string]$ss.time_base)) {
            Log ("ERROR: the recovered opening's {0} counts time in units of {1} s, the master's in {2} s." -f $kind, $ss.time_base, $ms.time_base)
            Log  "       Joined by stream copy, the result would have the wrong length and play"
            Log  "       at the wrong speed (CONSTRAINT 14). The output was not written."
            Log  "       Please report this, with the output of: vodpatch.bat doctor"
            Finish 1
        }
    }
    Log ("The opening and the master count time in the same units (video {0}, audio {1})." -f `
         (Get-VideoStream $si).time_base, (Get-AudioStream $si).time_base)
}

# The finished file's length is CHECKED, not just printed: a join that broke
# the timestamps (CONSTRAINT 14) used to report SUCCESS right next to
# "Duration 40 691s (expected ~10 417s)". Each stream is compared with what its
# two pieces add up to - the concat demuxer starts the master at the opening's
# full length - so a master whose audio legitimately ends a little before its
# video is not mistaken for a broken result. A wrong result is renamed, never
# left looking finished.
function Assert-FinalLength([string]$outFile, [string]$segPath, $masterInfo) {
    $o  = Probe $outFile
    $si = Probe $segPath
    if (-not $o -or -not $si) { Log "ERROR: could not probe the result to check its length."; Finish 1 }
    $head = [double]$si.format.duration
    $bad = @()
    foreach ($kind in @("video", "audio")) {
        $ms = $masterInfo.streams | Where-Object { $_.codec_type -eq $kind } | Select-Object -First 1
        $os = $o.streams          | Where-Object { $_.codec_type -eq $kind } | Select-Object -First 1
        if (-not $ms -or -not $os -or -not $ms.duration -or -not $os.duration) { continue }
        $want = $head + [double]$ms.duration
        $got  = [double]$os.duration
        $tol  = [Math]::Max(2.0, 0.001 * $want)
        if ([Math]::Abs($got - $want) -gt $tol) { $bad += ("{0} {1}s instead of {2}s" -f $kind, (F2 $got), (F2 $want)) }
    }
    if ($bad.Count) {
        $broken = Get-SiblingPath $outFile "broken"
        Remove-Item -LiteralPath $broken -Force -ErrorAction SilentlyContinue
        Move-Item -LiteralPath $outFile -Destination $broken -Force
        Log ("ERROR: the result has the wrong length: " + ($bad -join ", ") + ".")
        Log ("       It was renamed to {0}" -f $broken)
        Log  "       so it cannot be mistaken for a good file - delete it. Your originals are"
        Log  "       untouched. Please report this, with the output of: vodpatch.bat doctor"
        Finish 1
    }
    Log ("SUCCESS -> {0}" -f $outFile)
    Log ("Length {0}s, as expected (the opening's {1}s + the master's {2}s)." -f `
         (F2 ([double]$o.format.duration)), (F2 $head), (F2 ([double]$masterInfo.format.duration)))
}

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

# One rule for when to guess, shared by the stages and the menu so the two can
# never disagree: nothing typed, and the default names are not both present.
# (The stages used to guess only when NEITHER default existed, so a folder with
# HyperDeck_0001.mp4 plus a differently named VOD worked in the menu and failed
# from the command line with an untrue "could not tell which two".)
function Test-ShouldGuess() {
    return (-not $MasterGiven -and -not $VodGiven -and
            -not ((Test-Path -LiteralPath $Master) -and (Test-Path -LiteralPath $Vod)))
}

function Require-Inputs() {
    $haveMaster = Test-Path -LiteralPath $Master
    $haveVod    = Test-Path -LiteralPath $Vod
    if ($haveMaster -and $haveVod) { return }

    # A path the user typed that does not exist: say exactly which one, so a
    # typo is obvious instead of hiding behind a generic "could not find".
    # Checked BEFORE guessing: a guess must never replace a path the user gave.
    $typedMissing = @()
    if ($MasterGiven -and -not $haveMaster) { $typedMissing += ("the local recording (-Master): {0}" -f $Master) }
    if ($VodGiven    -and -not $haveVod)    { $typedMissing += ("the stream VOD (-Vod):          {0}" -f $Vod) }
    if ($typedMissing.Count) {
        Log "ERROR: this file does not exist:"
        foreach ($t in $typedMissing) { Log ("       " + $t) }
        Log "       Check the path, or leave it out to let the tool find the files itself."
        Finish 1
    }

    # Work out which files they are from what is actually in the folder,
    # rather than insisting on any particular filename. Only when the user
    # typed neither path.
    if ((Test-ShouldGuess) -and (Find-Sources)) {
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
using System.Collections.Generic;
using System.Runtime.InteropServices;

// C# 5 only (Windows PowerShell 5.1 compiles with the .NET Framework compiler):
// no tuples, no string interpolation, no pattern matching, no Span, no Math.Clamp.
public static class Sig {

    // ---- audio ----------------------------------------------------------------
    // Pearson correlation of r (the master's opening) against s (the whole VOD)
    // at every lag 0..m-nMin. Where r would run past the end of s, only its first
    // (m - lag) samples take part -- partial overlap -- but never fewer than nMin.
    // NaN where either side is flat (digital silence carries no information).
    public static double[] PearsonPartial(double[] r, double[] s, int nMin) {
        int n = r.Length, m = s.Length;
        if (nMin < 2 || n < nMin || m < nMin) return new double[0];
        double[] pr = new double[n + 1], pr2 = new double[n + 1];
        for (int i = 0; i < n; i++) { pr[i + 1] = pr[i] + r[i]; pr2[i + 1] = pr2[i] + r[i] * r[i]; }
        double[] ps = new double[m + 1], ps2 = new double[m + 1];
        for (int i = 0; i < m; i++) { ps[i + 1] = ps[i] + s[i]; ps2[i + 1] = ps2[i] + s[i] * s[i]; }
        int lags = m - nMin;
        double[] c = new double[lags + 1];
        for (int lag = 0; lag <= lags; lag++) {
            int len = Math.Min(n, m - lag);
            double rs = pr[len], rs2 = pr2[len];
            double ss = ps[lag + len] - ps[lag], ss2 = ps2[lag + len] - ps2[lag];
            double rv = rs2 - rs * rs / len, sv = ss2 - ss * ss / len;
            if (rv <= 1e-9 * (Math.Abs(rs2) + 1e-30) || sv <= 1e-9 * (Math.Abs(ss2) + 1e-30)) { c[lag] = double.NaN; continue; }
            double dot = 0;
            for (int i = 0; i < len; i++) dot += r[i] * s[lag + i];
            double v = (dot - rs * ss / len) / Math.Sqrt(rv * sv);
            if (v > 1.0) v = 1.0; else if (v < -1.0) v = -1.0;
            c[lag] = v;
        }
        return c;
    }

    // [median, MAD] of the finite values of a curve.
    public static double[] MedianMad(double[] c) {
        List<double> v = new List<double>();
        for (int i = 0; i < c.Length; i++) if (!double.IsNaN(c[i]) && !double.IsInfinity(c[i])) v.Add(c[i]);
        if (v.Count == 0) return new double[] { double.NaN, double.NaN };
        double[] a = v.ToArray(); Array.Sort(a);
        double med = a[a.Length / 2];
        for (int i = 0; i < a.Length; i++) a[i] = Math.Abs(a[i] - med);
        Array.Sort(a);
        return new double[] { med, a[a.Length / 2] };
    }

    // Up to k local extrema of a curve, best first. A sample qualifies only if no
    // finite sample within +/-radius beats it (ties go to the earlier sample), so
    // the walls of one basin are never returned as extra candidates.
    public static int[] Extrema(double[] c, int radius, int k, bool maximise) {
        List<int> cand = new List<int>();
        for (int i = 0; i < c.Length; i++) {
            double v = c[i];
            if (double.IsNaN(v)) continue;
            bool ok = true;
            int lo = Math.Max(0, i - radius), hi = Math.Min(c.Length - 1, i + radius);
            for (int j = lo; j <= hi; j++) {
                if (j == i || double.IsNaN(c[j])) continue;
                bool better = maximise ? (c[j] > v || (c[j] == v && j < i)) : (c[j] < v || (c[j] == v && j < i));
                if (better) { ok = false; break; }
            }
            if (ok) cand.Add(i);
        }
        int[] idx = cand.ToArray();
        Array.Sort(idx, (x, y) => {
            int cmp = maximise ? c[y].CompareTo(c[x]) : c[x].CompareTo(c[y]);
            return cmp != 0 ? cmp : x.CompareTo(y);
        });
        int nOut = Math.Min(k, idx.Length);
        int[] o = new int[nOut];
        Array.Copy(idx, o, nOut);
        return o;
    }

    // ---- pictures ---------------------------------------------------------------
    // 4x4 box average: every w x h grey frame becomes (w/4) x (h/4).
    public static byte[] Reduce4(byte[] src, int w, int h) {
        int fb = w * h, n = src.Length / fb, w2 = w / 4, h2 = h / 4, fb2 = w2 * h2;
        byte[] o = new byte[n * fb2];
        for (int f = 0; f < n; f++)
            for (int y = 0; y < h2; y++)
                for (int x = 0; x < w2; x++) {
                    int s = 0;
                    for (int dy = 0; dy < 4; dy++)
                        for (int dx = 0; dx < 4; dx++) s += src[f * fb + (y * 4 + dy) * w + x * 4 + dx];
                    o[f * fb2 + y * w2 + x] = (byte)((s + 8) / 16);
                }
        return o;
    }

    static double Dist(byte[] a, int ao, byte[] b, int bo, int fb) {
        long s = 0;
        for (int k = 0; k < fb; k++) { int d = a[ao + k] - b[bo + k]; s += d < 0 ? -d : d; }
        return (double)s / fb;
    }

    // Keyframe lattice. Convention: VOD time = master time + lag.
    // For each lag L = lag0 + i*step, the mean distance between every VOD
    // keyframe (absolute time t[k], ascending) and the master frame nearest to
    // t[k] - L, over the keyframes that land inside the master window
    // (master frame j sits at j/fps). NaN when fewer than minPairs land.
    public static double[] Lattice(byte[] kf, double[] t, byte[] ms, int fb, double fps,
                                   double lag0, double step, int nLags, int minPairs, int[] pairs) {
        int nk = t.Length, nm = ms.Length / fb;
        double[] c = new double[nLags];
        int first = 0;
        for (int i = 0; i < nLags; i++) {
            double lag = lag0 + i * step;
            while (first < nk && Math.Floor((t[first] - lag) * fps + 0.5) < 0) first++;
            double sum = 0; int cnt = 0;
            for (int k = first; k < nk; k++) {
                int j = (int)Math.Floor((t[k] - lag) * fps + 0.5);
                if (j >= nm) break;
                sum += Dist(kf, k * fb, ms, j * fb, fb); cnt++;
            }
            if (pairs != null) pairs[i] = cnt;
            c[i] = cnt >= minPairs ? sum / cnt : double.NaN;
        }
        return c;
    }

    // Mean absolute grey-level difference of a reference run (refCount frames
    // from refStart in rf) against the search frames of sf (from sStart, sCount
    // frames), at every lag 0..sCount-refCount.
    public static double[] SadCurve(byte[] rf, int refStart, int refCount,
                                    byte[] sf, int sStart, int sCount, int fb) {
        int lags = sCount - refCount + 1;
        if (refCount < 1 || lags < 1) return new double[0];
        double[] o = new double[lags];
        for (int lag = 0; lag < lags; lag++) {
            long s = 0;
            for (int f = 0; f < refCount; f++) {
                int ro = (refStart + f) * fb, so = (sStart + lag + f) * fb;
                for (int k = 0; k < fb; k++) { int d = rf[ro + k] - sf[so + k]; s += d < 0 ? -d : d; }
            }
            o[lag] = (double)s / ((double)refCount * fb);
        }
        return o;
    }

    // SadCurve after matching each search run's brightness and contrast to the
    // reference run's (same mean and standard deviation over the whole run). A
    // VOD whose levels differ from the master's - full vs limited range, another
    // gamma, a brighter encode - then still measures near its noise floor at the
    // true lag instead of ~10/255 everywhere, which is what lets the frame check
    // compare a match with the moment's own motion (see Test-Candidate). Same
    // units (0-255) and lags as SadCurve.
    public static double[] SadCurveMatched(byte[] rf, int refStart, int refCount,
                                           byte[] sf, int sStart, int sCount, int fb) {
        int lags = sCount - refCount + 1;
        if (refCount < 1 || lags < 1) return new double[0];
        double nPix = (double)refCount * fb;
        double rs = 0, rq = 0;
        for (int f = 0; f < refCount; f++) {
            int ro = (refStart + f) * fb;
            for (int k = 0; k < fb; k++) { double x = rf[ro + k]; rs += x; rq += x * x; }
        }
        double rMean = rs / nPix;
        double rStd  = Math.Sqrt(Math.Max(0.0, rq / nPix - rMean * rMean));
        // per-frame sums, so each lag's run statistics cost refCount additions
        double[] fs = new double[sCount], fq = new double[sCount];
        for (int f = 0; f < sCount; f++) {
            int so = (sStart + f) * fb; double a = 0, b = 0;
            for (int k = 0; k < fb; k++) { double x = sf[so + k]; a += x; b += x * x; }
            fs[f] = a; fq[f] = b;
        }
        double[] o = new double[lags];
        for (int lag = 0; lag < lags; lag++) {
            double ss = 0, sq = 0;
            for (int f = 0; f < refCount; f++) { ss += fs[lag + f]; sq += fq[lag + f]; }
            double sMean = ss / nPix;
            double sStd  = Math.Sqrt(Math.Max(0.0, sq / nPix - sMean * sMean));
            double g = rStd / Math.Max(sStd, 0.5);          // a flat search run is not stretched
            double s = 0;
            for (int f = 0; f < refCount; f++) {
                int ro = (refStart + f) * fb, so = (sStart + lag + f) * fb;
                for (int k = 0; k < fb; k++) {
                    double d = rf[ro + k] - (rMean + (sf[so + k] - sMean) * g);
                    s += d < 0 ? -d : d;
                }
            }
            o[lag] = s / nPix;
        }
        return o;
    }

    // How distinctive a master run is: the SAD of the run (n frames from j)
    // against the same run d frames earlier and d frames later; the smaller.
    public static double SelfSad(byte[] m, int j, int n, int d, int fb) {
        int nm = m.Length / fb;
        if (j - d < 0 || j + d + n > nm) return double.NaN;
        double a = SadCurve(m, j, n, m, j - d, n, fb)[0];
        double b = SadCurve(m, j, n, m, j + d, n, fb)[0];
        return Math.Min(a, b);
    }

    // Indices of keys in ascending order (descending if asked). Sorting is done
    // here because PowerShell may hand a method a COPY of an object[] argument,
    // which makes [Array]::Sort(keys, items) silently sort the copy.
    public static int[] Order(double[] keys, bool descending) {
        int[] idx = new int[keys.Length];
        double[] k = new double[keys.Length];
        for (int i = 0; i < keys.Length; i++) { idx[i] = i; k[i] = descending ? -keys[i] : keys[i]; }
        Array.Sort(idx, (x, y) => { int c = k[x].CompareTo(k[y]); return c != 0 ? c : x.CompareTo(y); });
        return idx;
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

# CONSTRAINT 4 -- analysis passes write to a rawvideo or s16le sink on NUL,
# NEVER to "-f null". The null muxer enforces strictly increasing timestamps
# and aborts with "Application provided invalid, non monotonically increasing
# dts" on VODs with duplicate DTS, which a VOD stitched from .ts segments
# routinely has. rawvideo and s16le do not care. Every VOD input also gets
# -fflags +genpts+igndts ($TsFix).
#
# Timestamps: pts_time printed by metadata=print is ABSOLUTE only on an
# unseeked read (or -ss 0). After a real seek ffmpeg rebases the output
# timeline to the seek point - measured on a VOD whose video starts at 0.996s:
# no -ss and -ss 0 both print 0.996, -ss 50 prints 0.013. So a seeked read is
# always indexed from the REQUESTED seek point (seek + index/fps), never from
# the pts it prints.

# RMS loudness envelope of the audio, one value per $stepSec.
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

# CONSTRAINT 12 -- large arrays handed between PowerShell and the C# kernels.
# A byte[] returned bare from a function is UNROLLED by PowerShell into an
# object[] of boxed bytes, and every later C# call then converts it back:
# measured 133 s instead of 0.1 s on the master's 8 MB of frames. Hence the
# leading comma below, which returns the array as one object. The same
# copy-on-call behaviour is why sorting is done by [Sig]::Order and never by
# [Array]::Sort(keys, items): PowerShell may pass a COPY of an object[], and
# Array.Sort then silently sorts the copy.
function Get-RawFrames($path, $start, $duration, $tag, $w, $h, $fps) {
    $out = "frames_$tag.gray"                      # CONSTRAINT 3: relative name
    if (Test-Path $out) { Remove-Item $out -Force }
    $ok = FF (@("-hide_banner", "-loglevel", "error", "-y") + $TsFix +
              @("-ss", (F $start), "-t", (F $duration), "-i", $path,
                "-an", "-sn", "-dn", "-map", "0:v:0",
                "-vf", ("scale={0}:{1},format=gray" -f (FI $w), (FI $h)), "-r", (F $fps),
                "-f", "rawvideo", "-pix_fmt", "gray", $out)) "raw frames ($tag)"
    if (-not $ok) { return $null }                 # do not match on a truncated buffer
    $p = Join-Path $WorkDir $out
    if (-not (Test-Path $p)) { return $null }
    return ,[System.IO.File]::ReadAllBytes($p)
}

# ---------------------------------------------------------------------------
# Offset detection
#
# Two cheap searches each suggest up to three candidate offsets, and neither
# decides anything on its own:
#   - sound:    the loudness envelope of the master's opening, correlated along
#               the whole VOD, partial overlap allowed;
#   - pictures: every VOD keyframe compared against the master's opening.
# Every candidate is then checked frame by frame, at up to three moments of the
# master that look different from their surroundings ("anchors"). A candidate
# is accepted only if at least two anchors land on the SAME frame.
#
# Why not a single correlation any more: the old detector correlated scene-
# change scores ("motion energy"). On near-static footage - people standing
# and talking - motion energy is flat and the correlation was noise (0.455
# against a runner-up of 0.432, i.e. no answer at all). Worse, it slid a 90 s
# reference along the VOD and required full overlap, so on a 192 s VOD it
# could not reach any lag past 101 s; the true answer was 111.47 s. And no
# peak-to-runner-up ratio can rescue it: on static footage every frame
# resembles every other, and the ratio sat at about 1.35 whether the answer
# was right or wrong. The absolute frame distance is what separates them:
# 0.3-0.6/255 for a true match, 36-42/255 for a wrong one.
# ---------------------------------------------------------------------------

$ThumbW = 64; $ThumbH = 36; $ThumbBytes = $ThumbW * $ThumbH

# The smallest offset worth recovering, in seconds (about six frames). Below it
# the answer is "nothing is missing", from the picture and the sound alike, and
# the seam test - which needs some VOD before the cut - refuses it. One number,
# used everywhere, so no two parts of the tool can disagree about it.
$MinOffset = 0.1

# The frame check's three numbers (mean grey differences, /255):
#
# $MinSelf - how much a master moment must differ from itself one second
#   earlier and later (its "self") to be used at all. A frozen frame (a still
#   "starting soon" screen: self 0.02) matches every frame of that still
#   equally well, so its best frame is arbitrary; it used to CONTRADICT a real
#   match (two moments landing 64 frames apart). Kept low on purpose: a small
#   facecam over a static layout, or a calm talking head, has real moments at
#   self 0.1-0.6, and a floor of 1.0 threw all of them away.
#
# A moment HITS when its best lag is off the window edge and its difference
# there is <= min(12, max($HitRatio * self, $HitNear)):
#   $HitRatio - small compared with the moment's own motion. With little motion
#     in the picture, a WRONG position also scores low in absolute terms (a
#     facecam over a static layout: 0.96 and 3.51/255 at a wrong frame), so an
#     absolute limit alone let two weak moments agree on a wrong frame and
#     start the merge 46 s off. The true match is measured against the master
#     after matching its brightness and contrast (Sig.SadCurveMatched), so a
#     colour-range mismatch reads 1.5 instead of 10.4.
#   $HitNear  - or near-perfect outright: on very calm footage the true match
#     sits at the encoding noise (0.22) while the moment's own motion is barely
#     above it (self 0.12-0.2), so no ratio could accept it.
# Measured over 149 cases with known answers (both real jobs and their
# 720p30 / range / overlay / 30 s-overlap variants, a loop, a mirror, facecam
# composites at 4 sizes x 4 cut points x 4 overlaps with and without audio, a
# calm talking head, stills): 0 wrong verifications and the true frame
# verified wherever the pictures can match, across the whole range
# $HitRatio 0.35-1.0 x $HitNear 0.3-0.8. The values sit in the middle: the
# highest true ratio was 0.35 (a burnt-in overlay), the lowest wrong absolute
# hit 0.36. The old rule (<= 12 alone) verified 10 wrong frames.
$MinSelf  = 0.1
$HitRatio = 0.5
$HitNear  = 0.4

# Every keyframe of the VOD as a 64x36 grey thumbnail, read UNSEEKED so that
# pts_time is absolute. Keyframes rather than a fixed frame rate because the
# decoder can skip everything else: on a 2 s GOP that is ~6x cheaper than a
# full decode, which is the difference between minutes and a quarter of an
# hour on a six-hour VOD.
#   -skip_frame nokey, NOT -discard nokey: -discard leaks the non-key frames at
#   the head of the first GOP.
#   metadata=print writes nothing unless a metadata=add runs before it.
#   The select term keeps at most one picture every 0.5 s, so an all-intra VOD
#   (or a decoder that ignores -skip_frame) cannot flood the search.
function Get-KeyframeThumbs($path) {
    $txt = "keyframes_vod.txt"; $out = "keyframes_vod.gray"      # CONSTRAINT 3: relative
    foreach ($p in @($txt, $out)) { if (Test-Path $p) { Remove-Item $p -Force } }
    $vf = ("select='eq(pict_type\,PICT_TYPE_I)*(isnan(prev_selected_t)+gte(t-prev_selected_t\,{4}))'," +
           "scale={0}:{1},format=gray," +
           "metadata=mode=add:key=vodpatch:value={2},metadata=mode=print:file={3}") -f `
           (FI $ThumbW), (FI $ThumbH), (FI 1), $txt, (F 0.5)
    $ok = FF (@("-hide_banner", "-loglevel", "error", "-y") + $TsFix +
              @("-skip_frame", "nokey", "-i", $path,
                "-an", "-sn", "-dn", "-map", "0:v:0", "-vf", $vf,
                "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", $out)) "VOD keyframes"
    if (-not $ok -or -not (Test-Path $out) -or -not (Test-Path $txt)) { return $null }
    $inv   = [System.Globalization.CultureInfo]::InvariantCulture
    $times = New-Object System.Collections.Generic.List[double]
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $WorkDir $txt))) {
        if ($line -match 'pts_time:(-?[0-9.]+)') { $times.Add([double]::Parse($Matches[1], $inv)) }
    }
    $pix = [System.IO.File]::ReadAllBytes((Join-Path $WorkDir $out))
    $n = [int][Math]::Floor($pix.Length / $ThumbBytes)
    if ($n -ne $times.Count -or $n -lt 2) {
        Log ("  (keyframe read gave {0} pictures and {1} timestamps - picture search skipped)" -f $n, $times.Count)
        return $null
    }
    for ($i = 1; $i -lt $n; $i++) {
        if ($times[$i] -le $times[$i - 1]) { Log "  (keyframe timestamps out of order - picture search skipped)"; return $null }
    }
    return @{ pix = $pix; t = $times.ToArray() }
}

# Anchors: moments of the master's opening (on its frame grid), ranked by how
# much they differ from the master 1 s before and 1 s after. A distinctive
# moment is one a wrong offset cannot imitate by accident. Best first.
function Get-Anchors([byte[]]$mB, [double]$fps) {
    $refN   = [int][Math]::Round(0.5 * $fps)
    $shiftN = [int][Math]::Round(1.0 * $fps)
    $stepN  = [int][Math]::Round(0.5 * $fps)
    $mCount = [int][Math]::Floor($mB.Length / $ThumbBytes)
    $js = New-Object System.Collections.Generic.List[int]
    $ss = New-Object System.Collections.Generic.List[double]
    for ($j = [int][Math]::Ceiling(2.0 * $fps); $j + $refN + $shiftN -le $mCount; $j += $stepN) {
        $s = [Sig]::SelfSad($mB, $j, $refN, $shiftN, $ThumbBytes)
        if (-not [double]::IsNaN($s) -and $s -ge $MinSelf) { $js.Add($j); $ss.Add($s) }
    }
    $list = @()
    foreach ($i in [Sig]::Order($ss.ToArray(), $true)) {             # CONSTRAINT 12
        $list += ,@{ t = $js[$i] / $fps; j = $js[$i]; self = $ss[$i] }
    }
    return ,$list
}

# The frame check for one candidate offset c. At up to 3 anchors that fit in
# the overlap and sit >= 5 s apart, slide the master's 0.5 s run over +/-1.5 s
# of VOD read at the master's frame rate, and take the lowest mean difference.
#
# Offset convention: offset = n / fps_master, where n is the slot of the VOD
# frame showing master frame 0 on ffmpeg's constant-rate grid at the master's
# rate, counted from VOD time 0 - the same grid the merge's own opening encode
# (-i VOD -t offset -r <master rate>) produces. A read seeked to exactly s0/fps
# reproduces slots s0+1, s0+2, ... byte for byte, but slot s0 itself is
# sometimes a duplicate, so the FIRST FRAME OF EVERY SEEKED READ IS DROPPED.
#
# An anchor hits when its best lag is not within 0.25 s of the window edge (a
# best at the edge means the real best is outside the window) and its
# brightness-matched difference passes the rule above $MinSelf. A candidate
# passes with >= 2 hits whose frame slots agree to within one frame.
#
# Anchors normally sit >= 5 s apart. When the overlap is so short that only one
# fits at that spacing (a VOD that ends 8-10 s after the master starts), they
# are picked again at >= 2 s: two different moments of the master landing on
# the same VOD frame is still independent evidence, and without the retry a
# genuine match was reported as "the files probably do not overlap".
function Select-Anchors($anchors, [double]$aMax, [double]$spacing) {
    $chosen = @()
    foreach ($an in $anchors) {
        if ($an.t -gt $aMax) { continue }
        $far = $true
        foreach ($q in $chosen) { if ([Math]::Abs($q.t - $an.t) -lt $spacing) { $far = $false } }
        if ($far) { $chosen += ,$an }
        if ($chosen.Count -ge 3) { break }
    }
    return ,$chosen
}

function Test-Candidate([double]$c, $anchors, [byte[]]$mB, [double]$fps, [double]$vodDur, [string]$tag) {
    $refN = [int][Math]::Round(0.5 * $fps)
    $pad  = 1.5
    $span = 2 * $pad + 0.5 + 3.0 / $fps
    $aMax = $vodDur - $c - ($pad + 1.0)
    $chosen = Select-Anchors $anchors $aMax 5.0
    # Fewer than two anchors has two different causes: the VOD ends too soon
    # (the overlap removed them), or the master's first minute offers only one
    # distinctive moment. Only the first is a "short overlap"; the second used to
    # be reported as one ("the VOD ends too soon ... about 170 s of overlap").
    $inMaster = (Select-Anchors $anchors ([double]::MaxValue) 5.0).Count
    $short  = ($chosen.Count -lt 2 -and $inMaster -ge 2)
    if ($chosen.Count -lt 2) { $chosen = Select-Anchors $anchors $aMax 2.0 }
    $res = @(); $k = 0
    foreach ($an in $chosen) {
        $k++
        $s0 = [long][Math]::Floor(($c + $an.t - $pad) * $fps)
        if ($s0 -lt 0) { $s0 = 0 }
        $sf = Get-RawFrames $Vod ($s0 / $fps) $span ("{0}_a{1}" -f $tag, $k) $ThumbW $ThumbH $fps
        $sc = 0; if ($sf) { $sc = [int][Math]::Floor($sf.Length / $ThumbBytes) }
        if ($sc - 1 -lt $refN + [int][Math]::Floor(2 * $pad * $fps)) {
            $res += ,@{ t = $an.t; self = $an.self; avail = $false }     # does not count either way
            continue
        }
        $cv = [Sig]::SadCurveMatched($mB, $an.j, $refN, $sf, 1, $sc - 1, $ThumbBytes)   # 1 = drop frame 0
        $bi = 0
        for ($i = 1; $i -lt $cv.Length; $i++) { if ($cv[$i] -lt $cv[$bi]) { $bi = $i } }
        $edgeN = [int][Math]::Round(0.25 * $fps)
        $edge  = ($bi -lt $edgeN -or $bi -gt $cv.Length - 1 - $edgeN)
        $limit = [Math]::Min(12.0, [Math]::Max($HitRatio * $an.self, $HitNear))
        $res += ,@{ t = $an.t; self = $an.self; avail = $true; slot = ($s0 + 1 + $bi - $an.j);
                   sad = $cv[$bi]; edge = $edge; lag = (($s0 + 1 + $bi) / $fps) - ($c + $an.t);
                   hit = ((-not $edge) -and $cv[$bi] -le $limit) }
    }
    $hits  = @($res | Where-Object { $_.avail -and $_.hit })
    $avail = @($res | Where-Object { $_.avail }).Count
    $verified = $false; $before = $false; $single = $false; $lone = $null
    $slot = $null; $worst = [double]::NaN
    # Below $MinOffset (0.1 s, about six frames) there is nothing worth
    # recovering and nothing the seam test could show - the same threshold the
    # sound rule and the seam test use, so picture and sound can never disagree
    # about whether something is missing.
    $minSlot = [Math]::Ceiling($MinOffset * $fps)
    $agree = $false
    if ($hits.Count -ge 1) {
        $ns = @($hits | ForEach-Object { [long]$_.slot } | Sort-Object)
        $agree = (($ns[$ns.Count - 1] - $ns[0]) -le 1)
    }
    if ($hits.Count -ge 2 -and $agree) {
        # The frame most hits land on; on a tie (two hits one frame apart) the
        # one with the lower difference. Taking the lower slot put the merge a
        # frame early whenever two hits split 8990 / 8991.
        $slot = $null; $bestN = 0; $bestSad = [double]::MaxValue
        foreach ($s in ($ns | Select-Object -Unique)) {
            $grp = @($hits | Where-Object { [long]$_.slot -eq $s })
            $mn  = ($grp | ForEach-Object { $_.sad } | Measure-Object -Minimum).Minimum
            if ($grp.Count -gt $bestN -or ($grp.Count -eq $bestN -and $mn -lt $bestSad)) {
                $slot = $s; $bestN = $grp.Count; $bestSad = $mn
            }
        }
        $worst = ($hits | ForEach-Object { $_.sad } | Measure-Object -Maximum).Maximum
        # Agreement below $minSlot is not a failed match: it PROVES the master
        # starts at (or before) the VOD's first frame, so nothing is missing.
        # Throwing that away used to end in an "offset=0" that every
        # recommended command then refused.
        if ($ns[0] -ge $minSlot) { $verified = $true } else { $before = $true }
    } elseif ($hits.Count -ge 1 -and $agree -and ($short -or $avail -eq 1)) {
        # One moment matched and there was no second one to check: the overlap
        # is too short for it (or its second anchor lies past the VOD's end), or
        # the master's first minute has only one distinctive moment. Not enough
        # to confirm, but far too much to report as "no match". On a normal
        # overlap with anchors to spare, one stray hit among three is exactly
        # what a WRONG candidate occasionally produces, and stays "no match".
        # A lone hit is weak evidence, so it may only SUGGEST an offset; it is
        # never allowed to claim "nothing is missing", and in the verdict it
        # blocks an automatic merge elsewhere instead of being ignored.
        $best1 = @($hits | Sort-Object { $_.sad })[0]
        if ([long]$best1.slot -ge $minSlot) {
            $single = $true
            $slot   = [long]$best1.slot
            $worst  = $best1.sad
            $lone   = if ($short -or $avail -lt $chosen.Count) { "overlap" } else { "master" }
        }
    }
    return @{ c = $c; anchors = $res; hits = $hits.Count; verified = $verified;
              before = $before; single = $single; slot = $slot; worst = $worst; lone = $lone }
}

function Format-Anchor($r) {
    if (-not $r.avail) { return ("{0}s: outside the VOD" -f (F2 $r.t)) }
    $s = "{0}s -> {1} ({2}) {3}s" -f (F2 $r.t), $r.slot, (F2 $r.sad), (F2 $r.lag)
    if ($r.edge) { $s += " edge" } elseif (-not $r.hit) { $s += " no" }
    return $s
}

# A command the user can paste into a console as-is. Numbers go through F()
# (never "111,467"), and the trailing backslash of a folder is trimmed because
# it would escape the closing quote.
#   $offset: a number     -> -Offset <number>
#            a string     -> -Offset <that text>, e.g. the placeholder SECONDS,
#                            which the user must replace (and which is refused
#                            as "not a number" if pasted unchanged)
#            $null or NaN -> no -Offset, so the saved verdict is consulted
# A merge or stripmerge command keeps the user's own -Out, -AudioShift, -Strip
# and -Force: a suggested command that silently dropped an audio correction or
# a chosen destination would be worse than none.
function Get-StageCommand([string]$stage, $offset, [string[]]$extra) {
    $s = 'powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Stage {1}' -f $ScriptSelf, $stage
    if ($offset -is [string]) {
        $s += " -Offset " + $offset
    } elseif ($null -ne $offset -and -not [double]::IsNaN([double]$offset)) {
        $s += " -Offset " + (F $offset)
    }
    if ($extra) { $s += " " + ($extra -join " ") }
    if ($stage -eq "merge" -or $stage -eq "stripmerge") {
        if ($Out)            { $s += ' -Out "{0}"' -f $OutFile }
        if ($AudioShiftText) { $s += " -AudioShift " + (F $AudioShift) }
        if ($Strip)          { $s += ' -Strip "{0}"' -f (Resolve-UserPath $Strip) }
        if ($Force)          { $s += " -Force" }
    }
    $s += ' -Root "{0}" -Master "{1}" -Vod "{2}" -Work "{3}"' -f `
          $Root.TrimEnd('\'), $Master, $Vod, $WorkDir.TrimEnd('\')
    return $s
}

# One verification still: VOD | master | 4x difference, where black means the
# same picture. Both inputs are seeked half a frame BEFORE the wanted frame so
# float rounding in -ss can never skip it, and setpts pairs the two first frames.
#
# CONSTRAINT 13 -- always write [Math]::Max(0.0, $x), never [Math]::Max(0, $x).
# With an integer first argument PowerShell picks the Int32 overload and
# truncates: [Math]::Max(0, 134.458) is 134 (measured). The old fine pass had
# this bug in the seek it used to position its search window.
function Write-Still([double]$offset, [double]$a, [string]$name, [double]$fps) {
    $fc = ("[0:v]setpts=PTS-STARTPTS,scale={0}:{1},setsar={3},format=yuv420p,split={4}[v0][v1];" +
           "[1:v]setpts=PTS-STARTPTS,scale={0}:{1},setsar={3},format=yuv420p,split={4}[m0][m1];" +
           "[v1]format=gray[vg];[m1]format=gray[mg];" +
           "[vg][mg]blend=all_mode=difference,lutyuv=y=val*{2},format=yuv420p[d];" +
           "[v0][m0][d]hstack=inputs={5}") -f (FI 480), (FI 270), (FI 4), (FI 1), (FI 2), (FI 3)
    $half = 0.5 / $fps
    $out = Join-Path $VerifyDir $name                                   # an output argument: absolute is fine
    FF (@("-y", "-hide_banner", "-loglevel", "error") + $TsFix +
        @("-ss", (F ([Math]::Max(0.0, $offset + $a - $half))), "-i", $Vod,
          "-ss", (F ([Math]::Max(0.0, $a - $half))), "-i", $Master,
          "-filter_complex", $fc, "-frames:v", (FI 1), "-q:v", (FI 3), $out)) "still $name" | Out-Null
    return (Test-Path -LiteralPath $out)
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

# The offset to use: typed on the command line (-Offset), or else the one the
# analysis saved. This NEVER refuses on the analysis verdict - the seam test
# calls it too, and the seam test is exactly how an unconfirmed offset gets
# checked. Refusing to merge an unconfirmed offset is Assert-MergeAllowed's job.
function Read-Offset() {
    if ($OffsetText) {
        $o = ConvertTo-Seconds $OffsetText                             # CONSTRAINT 11
        if ($null -eq $o) {
            Log ("ERROR: -Offset '{0}' is not a number of seconds. Write it like 111.466667" -f $OffsetText)
            Finish 1
        }
        Log ("Using the offset given on the command line: {0}s" -f (F $o))
        return $o
    }
    # The printed command carries the files and work folder in use: a bare
    # "vodpatch.bat analyze" analyzed whatever sat next to the script, into
    # another work folder, and sent the user round in a loop.
    if (-not (Test-Path -LiteralPath $SyncFile)) {
        Log "ERROR: no analysis result yet for these files. Run the analysis first:"
        Log ("         " + (Get-StageCommand "analyze" $null @()))
        Log "       or pass -Offset <seconds>."
        Finish 1
    }
    $cfg = Read-SyncFile
    $est = Get-EffectiveStatus $cfg
    if (-not $cfg.ContainsKey("offset")) {
        if ($est -eq "other_files") {
            Log "ERROR: the saved analysis was computed for other files and has no offset for"
            Log "       these. Run the analysis again, or pass -Offset <seconds>:"
            Log ("         " + (Get-StageCommand "analyze" $null @()))
        } elseif ($est -eq "nothing_missing") {
            Log "Nothing to recover: the analysis found that the local recording already starts"
            Log "at (or before) the VOD's first frame, so there is no opening to add."
            Log "If you know otherwise, pass -Offset <seconds>, or type it when the menu asks."
        } elseif ($est -eq "none") {
            Log "ERROR: the analysis found no match between these two files, so there is"
            Log "       no offset to use (see analyze_log.txt). To try one by hand, pass"
            Log "       -Offset <seconds>, or type it when the menu asks."
        } else {
            Log "ERROR: $SyncFile has no offset line. Run the analysis again:"
            Log ("         " + (Get-StageCommand "analyze" $null @()))
        }
        Finish 1
    }
    $o = 0.0
    if (-not [double]::TryParse($cfg["offset"], [System.Globalization.NumberStyles]::Float,
                                [System.Globalization.CultureInfo]::InvariantCulture, [ref]$o)) {
        Log ("ERROR: could not read the offset '{0}' from {1}." -f $cfg["offset"], $SyncFile)
        Finish 1
    }
    Log ("Using offset {0}s (from the analysis: {1})" -f (F $o), (Get-StatusText $est))
    return $o
}

# Called by merge and stripmerge only - never by the seam test.
#
# A wrong offset costs a multi-hour, tens-of-gigabytes re-run, so the merge
# starts on its own only when the analysis CONFIRMED the offset, and only for
# the very files it was computed on. Anything else - an unconfirmed verdict, a
# result file from an older version of the tool, or a result computed for other
# files - stops here with the exact commands to check it by hand. Typing the
# offset with -Offset is the user taking responsibility, and always proceeds.
function Assert-MergeAllowed([double]$offset, [string]$stageName) {
    if ($OffsetText) {
        Log "The offset was given on the command line, so the analysis verdict is not consulted."
        return
    }
    $st  = Get-EffectiveStatus (Read-SyncFile)
    $why = @()
    if ($st -eq "legacy") {
        $why += "this result comes from an older version of vodpatch, whose detector"
        $why += "is known to pick wrong offsets on footage with little motion."
        $why += "Run the analysis again (it takes seconds to a few minutes):"
        $why += ("  " + (Get-StageCommand "analyze" $null @()))
    } elseif ($st -eq "other_files") {
        $why += "this result was computed for other files (their sizes differ)."
        $why += "Run the analysis again:"
        $why += ("  " + (Get-StageCommand "analyze" $null @()))
    } elseif ($st -ne "confirmed" -and $st -ne "video_only") {
        # The seam-test command carries the saved offset (watching is harmless);
        # the merge command does NOT - the user types the offset they watched.
        # An offset the seam test would refuse is never offered for watching.
        $why += ("the analysis did not confirm the offset: " + (Get-StatusText $st) + ".")
        if ($offset -ge $MinOffset) {
            $why += "Watch the join with the seam test (about 10 seconds):"
            $why += ("  " + (Get-StageCommand "seamtest" $offset @()))
        } else {
            $why += "Find the cut by hand with the seam test (-Stage seamtest -Offset <seconds>),"
        }
        $why += "then run it again with the offset whose join you saw is clean, typed in place of SECONDS:"
        $why += ("  " + (Get-StageCommand $stageName "SECONDS" @()))
        $key  = if ($stageName -eq "stripmerge") { "[4]" } else { "[3]" }
        $why += ("(From the menu: [2] asks which offset to test, {0} asks which one to merge.)" -f $key)
    }
    if (-not $why.Count) { return }
    Log "The merge will NOT start:"
    foreach ($l in $why) { Log ("  " + $l) }
    Log "Nothing was written. Your originals are untouched."
    Finish 1
}

function Assert-SaneOffset([double]$offset, [double]$vodDur) {
    if ($offset -le 0) {
        Log ("ERROR: the offset is {0}s. It must be positive - it is how much of the VOD" -f (F $offset))
        Log  "       goes in front of the master. Re-run the analysis."
        Finish 1
    }
    # The same threshold as the analysis and the seam test ($MinOffset): a typed
    # -Offset 0.05 used to be merged although nothing could ever show its join.
    if ($offset -lt $MinOffset) {
        Log ("ERROR: the offset is {0}s. Below {1} s (about six frames) there is nothing" -f (F $offset), (F $MinOffset))
        Log  "       worth recovering, and the seam test cannot show the join."
        Finish 1
    }
    if ($offset -ge $vodDur) {
        Log ("ERROR: the offset is {0}s but the VOD is only {1}s long." -f (F $offset), (F2 $vodDur))
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
    $ts   = Get-Timescale $v                          # CONSTRAINT 14

    # EXACTLY n frames, where offset = n / fps (the offset convention of the
    # frame check). "-t offset" alone let one more frame in: the offset is
    # printed to 6 decimals, 111.466667 > 6688/60, so the VOD frame at slot n -
    # the one showing the master's very first picture - was encoded too. The
    # cut then showed that moment twice and left a one-frame (16.7 ms) hole in
    # the sound at the join.
    $rp = ([string]$v.r_frame_rate) -split '/'
    $nFrames = [long][Math]::Round($offset * [double]$rp[0] / [double]$rp[1])

    # timescale=, frames= and streams= are in the stamp so that an opening
    # cached by an older version (x264's own timescale, one frame too many, the
    # VOD's data track and chapters) is rebuilt rather than reused.
    $stamp = ("offset={0}|audioshift={1}|vod={2}|vodsize={3}|timescale={4}|frames={5}|streams=v,a" -f `
              (F $offset), (F $AudioShift), $Vod, (FI (Get-Item -LiteralPath $Vod).Length), (FI $ts), (FI $nFrames))

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
                    Log ("Reusing the cached opening: {0:N0} MB, {1}s (pass -Force to rebuild)" -f ((Get-Item $seg).Length/1MB), (F3 $sd))
                } else {
                    Log ("The cached opening is {0}s but the offset is {1}s - rebuilding." -f (F3 $sd), (F $offset))
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
        Log ("Encoding the recovered opening (VOD 0 - {0}s)..." -f (F $offset))
        $encArgs = Get-EncodeArgs $v $a
        # The streams are chosen explicitly: the VOD's video and sound, nothing
        # else. Left to ffmpeg's defaults, a Twitch VOD also contributed its data
        # track and its CHAPTERS - one "Special Events" chapter spanning the
        # whole VOD, which in a trimmed clip becomes a track longer than the
        # clip itself, and players size the timeline to it.
        $inArgs  = @("-i", $Vod)
        $mapArgs = @("-map", "0:v:0")
        $vi = Probe $Vod
        if ($vi -and (Get-AudioStream $vi)) {
            $mapArgs += @("-map", "0:a:0")
        } else {
            # No sound track in the VOD: silence in the master's format, so the
            # opening still has the master's streams (CONSTRAINT 5).
            Log "  the VOD has no sound track - the recovered opening gets silence"
            $cl = if ([int]$a.channels -eq 1) { "mono" } else { "stereo" }
            $inArgs += @("-f", "lavfi", "-t", (F $offset), "-i", ("anullsrc=r={0}:cl={1}" -f (FI $a.sample_rate), $cl))
            $mapArgs += @("-map", "1:a:0")
        }
        $mapArgs += @("-dn", "-sn", "-map_chapters", "-1")
        $tsArgs = @()
        if ($ts -gt 0) { $tsArgs = @("-video_track_timescale", (FI $ts)) }
        if (-not (FF (@("-y", "-hide_banner", "-loglevel", "warning") + $TsFix + $inArgs +
                      @("-t", (F $offset), "-frames:v", (FI $nFrames)) + $mapArgs + $encArgs + $tsArgs + @($part)) "opening encode")) {
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
    $firstFailure = $null                  # CONSTRAINT 10: keep ffmpeg's own words
    foreach ($m in $methods) {
        $po = Join-Path $WorkDir ("probe_tc." + $m.ext)
        Remove-Item -LiteralPath $po -Force -ErrorAction SilentlyContinue
        $call = @("-y", "-hide_banner", "-loglevel", "error",
                  "-i", $probeRaw, "-t", "5", "-i", $Master,
                  "-map", "0:v:0", "-map", ("1:" + (FI $didx)), "-map", "0:a:0",
                  "-c", "copy") + $m.a + @($po)
        $global:LASTEXITCODE = 0
        $mOut = & $ffmpeg @call 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $po)) {
            Log ("  method [{0,-20}] -> rejected by ffmpeg" -f $m.n)
            if (-not $firstFailure) { $firstFailure = $mOut }
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
        if ($firstFailure) {
            # The informative line is always FIRST; the tail is generic noise.
            Log "  ffmpeg's reason for the first rejected method:"
            $fl = $firstFailure -split "`r?`n" | Where-Object { $_.Trim() }
            foreach ($l in ($fl | Select-Object -First 6)) { Log ("  >  " + $l.Trim()) }
        }
        Log ""
        Log "None of the methods can reproduce the master's layout in the opening."
        Log "Use the fallback route instead ([4] in the menu, or vodpatch.bat stripmerge):"
        Log "it removes the timecode track from a copy of the master so both files are"
        Log "plain video+audio. It costs one extra full pass but cannot hit this problem."
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
              "-c", "copy") + $winner.a
    $tsm = Get-Timescale (Get-VideoStream $masterInfo)          # CONSTRAINT 14
    if ($tsm -gt 0) { $call += @("-video_track_timescale", (FI $tsm)) }
    $call += @($part)
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
    # CONSTRAINT 13: 150MB is an Int32 literal, so [Math]::Max(150MB, $x) picks
    # the Int32 overload - which THROWS once $x passes 2^31 bytes, i.e. on any
    # master above ~215 MB/s (4K ProRes and the like). $margin was then null,
    # -fs stopped the preflight exactly at the seam, and every merge failed.
    $margin      = [long][Math]::Max([double]150MB, $masterBytesPerSec * $secondsPast)
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
            # The time reached must also be PLAUSIBLE, and video and audio must
            # agree. A join that broke the timestamps (CONSTRAINT 14) "crossed
            # the seam" easily - its video claimed 552.8 s after ~80 s of
            # master - and passed; only the length told the truth.
            $vs = Get-VideoStream $ti; $as = Get-AudioStream $ti
            $vdur = if ($vs -and $vs.duration) { [double]$vs.duration } else { $tdur }
            $adur = if ($as -and $as.duration) { [double]$as.duration } else { $tdur }
            $maxPlausible = $offset + 1.5 * ($margin / $masterBytesPerSec) + 15
            if ($tdur -le ($offset + 2)) {
                Log ("  FAIL - the test only reached {0:N1}s; it never crossed the seam at {1}s." -f $tdur, (F $offset))
                Log  "         The join stopped early - read the ffmpeg lines above."
            } elseif ([Math]::Abs($vdur - $adur) -gt 1.0 -or $tdur -gt $maxPlausible) {
                Log ("  FAIL - the joined timeline is wrong: video {0}s, audio {1}s, but about {2}s" -f (F2 $vdur), (F2 $adur), (F2 ($offset + $margin / $masterBytesPerSec)))
                Log  "         were written. Joined like this the result would have the wrong length and"
                Log  "         play at the wrong speed (CONSTRAINT 14)."
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

    # Never leave a stale answer behind: if this run stops half way, there must
    # be no result from an earlier run for the merge to pick up by mistake.
    Remove-Item -LiteralPath $SyncFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $VerifyDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(check|cand)[0-9]+\.jpg$' } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $vv = Get-VideoStream $vodInfo
    $va = Get-AudioStream $vodInfo
    if (-not $vv) { Log "ERROR: the VOD has no video stream."; Finish 1 }
    if ($masterDur -lt 10 -or $vodDur -lt 10) {
        Log "ERROR: one of the files is shorter than 10 s - too short to match reliably."
        Finish 1
    }
    if ($vv.r_frame_rate -ne $v.r_frame_rate) {
        Log ("NOTE: the two files have different frame rates ({0} and {1}). The frame" -f $v.r_frame_rate, $vv.r_frame_rate)
        Log  "      check may then only agree to within a frame or two, and the result"
        Log  "      can come out unconfirmed - the seam test then decides."
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()

    # ---- 1. sound ----------------------------------------------------------------
    # The master's first 90 s of loudness, correlated along the whole VOD. Partial
    # overlap is allowed (down to 20 s), so a VOD that ends shortly after the
    # master starts can still be matched - the case that defeated the old
    # detector. Its score is judged against the curve's own spread (a robust z):
    # measured true matches r 0.82-1.00 with z 12.7-19.0; no-overlap pairs never
    # above r 0.35 or z 4.7.
    Log "Step 1/3 - sound: the loudness of the master's first 90 s, searched through the whole VOD..."
    $sound = @(); $soundStrong = $false; $soundTop = $null
    # Why a search could not run at all. "No match" is only an honest verdict
    # when both searches actually ran; otherwise these reasons are reported.
    $searchNotes = @()
    if ($a -and $va) {
        $aRefDur = [Math]::Min(90.0, $masterDur - 1)
        $envM = Get-AudioEnvelope $Master 0 $aRefDur 0.1 "master"
        $envV = Get-AudioEnvelope $Vod 0 ($vodDur - 1) 0.1 "vod"
        if ($envM.times.Count -ge 200 -and $envV.times.Count -ge 200) {
            $aRef  = Resample $envM $aRefDur 10
            $aSrc  = Resample $envV ($vodDur - 1) 10
            $curve = [Sig]::PearsonPartial($aRef, $aSrc, 200)          # >= 20 s of overlap
            $mm    = [Sig]::MedianMad($curve)
            foreach ($i in [Sig]::Extrema($curve, 20, 3, $true)) {
                $z = 0.0
                if ($mm[1] -gt 0) { $z = ($curve[$i] - $mm[0]) / (1.4826 * $mm[1]) }
                $sound += ,@{ t = $i / 10.0; r = $curve[$i]; z = $z }
            }
            if ($sound.Count) {
                $soundTop    = $sound[0]
                $soundStrong = ($soundTop.r -ge 0.5 -and $soundTop.z -ge 8.0)
            }
            $k = 0
            foreach ($s in $sound) {
                $k++
                $tagS = ""
                if ($k -eq 1) { $tagS = $(if ($soundStrong) { "   <- strong" } else { "   <- weak" }) }
                Log ("  sound match {0}: VOD {1}s  r={2}  z={3}{4}" -f $k, (F2 $s.t), (F3 $s.r), (F2 $s.z), $tagS)
            }
        } elseif ($aRefDur -lt 20.5 -or ($vodDur - 1) -lt 20.5) {
            Log "  too short for the sound search (it needs about 20 s of audio in each file) - skipping sound"
            $searchNotes += "the sound search needs about 20 s of audio in each file"
        } else {
            Log "  the audio could not be read - skipping sound"
            $searchNotes += "the audio of one of the files could not be read"
        }
    } else {
        Log "  one of the files has no audio - skipping sound"
        $searchNotes += "one of the files has no audio"
    }
    $tSound = $clock.Elapsed.TotalSeconds

    # ---- 2. pictures -------------------------------------------------------------
    Log "Step 2/3 - pictures: every VOD keyframe against the master's first 60 s..."
    $R  = [Math]::Min(60.0, $masterDur - 1)
    $mB = Get-RawFrames $Master 0 $R "master" $ThumbW $ThumbH $fps
    $picture = @()
    $kf = $null
    if ($mB) { $kf = Get-KeyframeThumbs $Vod }
    if ($mB -and $kf) {
        $m16 = [Sig]::Reduce4($mB, $ThumbW, $ThumbH)
        $k16 = [Sig]::Reduce4($kf.pix, $ThumbW, $ThumbH)
        $step = 0.1
        $nL = [int][Math]::Floor($kf.t[$kf.t.Length - 1] / $step) + 1
        $pairs = New-Object int[] $nL
        # How many keyframes must land inside the master's window for a lag to
        # count: 4 normally, fewer when the VOD's keyframes are so far apart that
        # 4 cannot fit (a 30 s GOP puts at most 2 in 60 s). These are only
        # suggestions - the frame check still decides - so relaxing this costs
        # nothing but a few extra seconds of checking.
        $gop = ($kf.t[$kf.t.Length - 1] - $kf.t[0]) / [Math]::Max(1.0, [double]($kf.t.Length - 1))
        $minPairs = [int][Math]::Max(2.0, [Math]::Min(4.0, [Math]::Floor($R / [Math]::Max(0.001, $gop))))
        $lat = [Sig]::Lattice($k16, $kf.t, $m16, ($ThumbBytes / 16), $fps, 0.0, $step, $nL, $minPairs, $pairs)
        foreach ($i in [Sig]::Extrema($lat, 20, 3, $false)) { $picture += ,@{ t = $i * $step; d = $lat[$i]; n = $pairs[$i] } }
        Log ("  {0} keyframes (one every {1}s), master {2} frames" -f $kf.t.Length, (F2 $gop), [int][Math]::Floor($mB.Length / $ThumbBytes))
        $k = 0
        foreach ($p in $picture) {
            $k++
            Log ("  picture match {0}: VOD {1}s  distance {2}/255 over {3} keyframes" -f $k, (F2 $p.t), (F2 $p.d), $p.n)
        }
        if (-not $picture.Count) {
            $searchNotes += ("the VOD has too few keyframes to compare (one every {0}s)" -f (F2 $gop))
        }
    } else {
        Log "  the keyframe search could not run - relying on sound for candidates"
        $searchNotes += "the picture search could not read the VOD's keyframes or the master's opening"
    }
    $tPicture = $clock.Elapsed.TotalSeconds

    # ---- 3. frame check ----------------------------------------------------------
    # Sound candidates first, then picture ones; two within 0.5 s are one
    # candidate. Every candidate gets the same independent frame-by-frame test.
    $cands = New-Object System.Collections.ArrayList
    foreach ($s in $sound) { [void]$cands.Add(@{ t = $s.t; src = "sound" }) }
    foreach ($p in $picture) {
        $dup = $null
        foreach ($e in $cands) { if ([Math]::Abs($e.t - $p.t) -lt 0.5) { $dup = $e } }
        if ($dup) { $dup.src = $dup.src + "+picture" } else { [void]$cands.Add(@{ t = $p.t; src = "picture" }) }
    }
    $anchors = @()
    if ($mB) { $anchors = Get-Anchors $mB $fps }
    if ($anchors.Count) {
        Log ("Step 3/3 - frame check: each candidate, frame by frame, at up to 3 distinctive moments of the master (the most distinctive is {0}s)..." -f (F2 $anchors[0].t))
    } elseif ($mB) {
        Log "Step 3/3 - frame check: skipped, the master's first minute does not change at all"
        Log "         (a still picture), so no moment of it can pin down a frame"
        $searchNotes += "the master's first minute is a still picture, so the frame check had nothing to compare"
    } else {
        Log "Step 3/3 - frame check: skipped, the master's opening could not be read"
    }
    $checked = @(); $ci = 0
    foreach ($c in $cands) {
        $ci++
        if (-not $anchors.Count) { break }
        $r = Test-Candidate $c.t $anchors $mB $fps $vodDur ("cand" + $ci)
        $r.src = $c.src
        $checked += ,$r
        $verdictTxt = if ($r.verified) { "MATCH, frame " + $r.slot } elseif ($r.before) { "MATCH at frame " + $r.slot + " - the master starts first" } elseif ($r.single) { "one moment only, frame " + $r.slot } else { "no match" }
        Log ("  {0}s ({1}): {2}  => {3}" -f (F2 $c.t), $c.src, (($r.anchors | ForEach-Object { Format-Anchor $_ }) -join ";  "), $verdictTxt)
    }

    # ---- 4. verdict --------------------------------------------------------------
    # Verified candidates whose frame slots agree to within 2 frames are one answer.
    $clusters = @()
    foreach ($r in ($checked | Where-Object { $_.verified } | Sort-Object { $_.worst })) {
        $in = $false
        foreach ($k in $clusters) { if ([Math]::Abs($k.slot - $r.slot) -le 2) { $in = $true } }
        if (-not $in) { $clusters += ,$r }
    }
    $beforeC = @($checked | Where-Object { $_.before })                          # master starts first
    $singleC = @($checked | Where-Object { $_.single } | Sort-Object { $_.worst }) # one moment only
    # "The master starts first" is an ANSWER too when judging whether the match
    # is unique. An opening seen at the VOD's very start AND again later (an
    # instant replay, a highlight) is ambiguous - it must never become a
    # confirmed offset at the replay, which is what happened when this evidence
    # was only consulted after the clusters: the merge then started on its own
    # and prepended the wrong footage.
    # A lone hit at ANOTHER frame counts too. It cannot confirm anything, but it
    # can contradict: on a facecam over a static layout, two weak anchors once
    # agreed on a wrong frame and won "confirmed by picture" - the merge started
    # on its own, 46 s off - while the true frame, matched far more closely at
    # the one anchor its short overlap allowed, was ignored.
    $singleElsewhere = @()
    foreach ($sg in $singleC) {
        $closeToCluster = $false
        foreach ($k in $clusters) { if ([Math]::Abs($k.slot - $sg.slot) -le 2) { $closeToCluster = $true } }
        if (-not $closeToCluster) { $singleElsewhere += ,$sg }
    }
    $answers = $clusters.Count + $(if ($beforeC.Count) { 1 } else { 0 }) +
               $(if ($clusters.Count -and $singleElsewhere.Count) { 1 } else { 0 })
    #   two or more answers (incl. "starts first",
    #     or a lone hit at another frame)          -> ambiguous
    #   one answer, strong sound within 0.5 s      -> confirmed        (merge allowed)
    #   one answer, no strong sound                -> video_only       (merge allowed)
    #   one answer, strong sound elsewhere         -> conflict
    #   the answer is "the master starts first"    -> nothing_missing
    #   picture matched at one moment only         -> unverified       (no second moment to check)
    #   strong sound at the VOD's very start       -> nothing_missing
    #   strong sound only                          -> audio_only
    #   nothing                                    -> none
    $status = "none"; $best = $null
    if ($answers -ge 2) {
        $status = "ambiguous"
    } elseif ($clusters.Count -eq 1) {
        $best = $clusters[0]
        $off  = $best.slot / $fps
        if (-not $soundStrong)                           { $status = "video_only" }
        elseif ([Math]::Abs($soundTop.t - $off) -le 0.5) { $status = "confirmed" }
        else                                             { $status = "conflict" }
    }
    elseif ($beforeC.Count)                                { $status = "nothing_missing" }
    elseif ($singleC.Count)                                { $status = "unverified" }
    elseif ($soundStrong -and $soundTop.t -lt $MinOffset)  { $status = "nothing_missing" }
    elseif ($soundStrong)                                  { $status = "audio_only" }

    # The offset= line: the best available candidate, so the seam test can run
    # without typing anything. "none" and "nothing_missing" write no offset line.
    $offsetOut = [double]::NaN
    if ($best)                        { $offsetOut = $best.slot / $fps }
    elseif ($clusters.Count)          { $offsetOut = $clusters[0].slot / $fps }
    elseif ($status -eq "unverified") { $offsetOut = $singleC[0].slot / $fps }
    elseif ($status -eq "audio_only") { $offsetOut = $soundTop.t }

    # the first master moment that fits inside the VOD for a given offset
    function Get-StillAnchor([double]$o) {
        foreach ($an in $anchors) { if ($an.t -le $vodDur - $o - 2.5) { return $an.t } }
        return $null
    }

    Log "--------------------------------------------------------------"
    $mergeOk = ($status -eq "confirmed" -or $status -eq "video_only")
    $tests = @()                                     # offsets offered for the seam test
    switch ($status) {
        "confirmed" {
            Log "RESULT: CONFIRMED. The picture matches frame for frame at separate moments,"
            Log ("        and the sound independently lands {0}s away." -f (F2 ([Math]::Abs($soundTop.t - $offsetOut))))
        }
        "video_only" {
            Log "RESULT: CONFIRMED BY PICTURE. The picture matches frame for frame at separate"
            Log "        moments. The sound could not help (silent, muted or different in the VOD)."
        }
        "conflict" {
            Log "RESULT: NOT CONFIRMED - the picture and the sound disagree."
            Log ("        picture: {0}s (frame {1}, frame check {2}/255)" -f (F $offsetOut), $best.slot, (F2 $best.worst))
            Log ("        sound  : {0}s (r={1}, z={2}), {3}s away" -f (F2 $soundTop.t), (F3 $soundTop.r), (F2 $soundTop.z), (F2 ($soundTop.t - $offsetOut)))
            Log "        Either the VOD's own sound is out of step with its picture, or the same"
            Log "        sound occurs twice in the VOD. If the seam test at the picture offset joins"
            Log ("        cleanly but the voices in the first part are off, add -AudioShift {0} to the merge." -f (F ([Math]::Round($offsetOut - $soundTop.t, 2))))
            $tests = @($offsetOut, $soundTop.t)
        }
        "ambiguous" {
            Log "RESULT: NOT CONFIRMED - the master's opening matches the VOD in more than one place"
            Log "        (a replay, or a looped scene):"
            if ($beforeC.Count) {
                Log  "          at the VOD's very start - the master starts first, so nothing is missing"
            }
            foreach ($k in $clusters) {
                Log ("          {0}s  (frame {1}, frame check {2}/255)" -f (F ($k.slot / $fps)), $k.slot, (F2 $k.worst))
                $tests += ($k.slot / $fps)
            }
            if ($clusters.Count) {
                foreach ($sg in $singleElsewhere) {
                    Log ("          {0}s  (frame {1}, {2}/255 - at one moment only)" -f (F ($sg.slot / $fps)), $sg.slot, (F2 $sg.worst))
                    $tests += ($sg.slot / $fps)
                }
            }
        }
        "unverified" {
            $sg1 = $singleC[0]
            Log ("RESULT: NOT CONFIRMED - the picture matches at {0}s (frame {1}, {2}/255), but only" -f (F $offsetOut), $sg1.slot, (F2 $sg1.worst))
            if ($sg1.lone -eq "master") {
                Log  "        at ONE moment of the master: its first minute has only one moment that"
                Log  "        changes enough to pin down a frame, so there was no second one to check."
            } else {
                Log  "        at ONE moment of the master: the VOD ends too soon after the master"
                Log ("        starts (about {0}s of overlap) to check a second one." -f (F2 ($vodDur - $offsetOut)))
            }
            $tests = @($offsetOut)
            foreach ($sg in $singleC) {
                if (@($tests | Where-Object { [Math]::Abs($_ - $sg.slot / $fps) -le 0.5 }).Count -eq 0) { $tests += ($sg.slot / $fps) }
            }
            if ($soundStrong -and [Math]::Abs($soundTop.t - $offsetOut) -gt 0.5) { $tests += $soundTop.t }
        }
        "audio_only" {
            Log ("RESULT: NOT CONFIRMED - the sound matches at {0}s (r={1}, z={2}), but the picture" -f (F2 $soundTop.t), (F3 $soundTop.r), (F2 $soundTop.z))
            Log "        could not confirm it frame by frame (different layout or overlay in the"
            Log "        VOD, or a master opening that barely moves). Sound alone is only good to"
            Log "        about 0.1 s, so expect a small jump at the cut."
            $tests = @($soundTop.t)
        }
        "nothing_missing" {
            if ($beforeC.Count) {
                Log ("RESULT: NOTHING IS MISSING. The master's picture lines up with the VOD at frame {0}," -f $beforeC[0].slot)
                Log  "        i.e. the local recording starts at (or before) the VOD's first frame."
            } else {
                Log "RESULT: NOTHING IS MISSING. The sound lines up at the very start of the VOD:"
                Log "        the two recordings begin together."
            }
            Log "        There is no opening to recover, so there is nothing to merge."
        }
        default {
            # A keyframe match this close (true matches measured 0.3-1.0/255,
            # wrong ones 27+) that the frame check still could not confirm is not
            # "nothing found" - say so, and offer it to the seam test.
            $near = @($picture | Where-Object { -not [double]::IsNaN($_.d) -and $_.d -lt 3.0 } | Sort-Object { $_.d })
            if ($near.Count) {
                Log ("RESULT: NO CONFIRMED MATCH - the picture search found a close match at {0}s" -f (F2 $near[0].t))
                Log ("        (distance {0}/255), but the frame check could not confirm it at two" -f (F2 $near[0].d))
                Log  "        separate moments. Watch it with the seam test before trusting it."
                $tests = @($near[0].t)
            } elseif ($searchNotes.Count) {
                Log "RESULT: NO MATCH FOUND - but the search could not run completely:"
                foreach ($n in $searchNotes) { Log ("          - " + $n) }
                Log "        So this does not prove the recordings are unrelated. If you know where the"
                Log "        cut is, try it by hand with the seam test (-Offset <seconds>)."
            } else {
                Log "RESULT: NO MATCH. Neither the picture nor the sound of the master's opening was"
                Log "        found in the VOD. These recordings probably do not overlap: different"
                Log "        sessions, a local recording that started after the stream ended, or"
                Log "        one that started before the stream."
            }
            if (-not $tests.Count) { Log "Nothing to merge. No offset was saved." }
            else                   { Log "No offset was saved." }
        }
    }
    # A keyframe match that is close (under 3/255) but was not confirmed is
    # worth watching whenever the result is unconfirmed: it was the TRUE offset
    # when a stray lone hit elsewhere became the "unverified" answer.
    if ($status -eq "unverified" -or $status -eq "audio_only" -or $status -eq "conflict") {
        foreach ($pc in @($picture | Where-Object { -not [double]::IsNaN($_.d) -and $_.d -lt 3.0 } | Sort-Object { $_.d } | Select-Object -First 2)) {
            if (@($tests | Where-Object { [Math]::Abs($_ - $pc.t) -le 0.5 }).Count -eq 0) {
                Log ("        Also worth watching: {0}s, a close picture match (distance {1}/255) the frame check could not confirm." -f (F2 $pc.t), (F2 $pc.d))
                $tests += $pc.t
            }
        }
    }
    # The seam test needs some VOD before the cut; never offer an offset it
    # would refuse (an offset of 0 used to loop the user back here forever).
    $tests = @($tests | Where-Object { $_ -ge $MinOffset })

    if ($mergeOk) {
        Log ("OFFSET: {0} s  = {1} frames at {2} fps = {3} min {4} s of recovered footage" -f `
             (F $offsetOut), $best.slot, $v.r_frame_rate, [Math]::Floor($offsetOut / 60), (F2 ($offsetOut % 60)))
        Log "Next: in the menu, [2] to watch the join, then [3] to merge. From a console:"
        Log ("  " + (Get-StageCommand "seamtest" $null @()))
        Log ("  " + (Get-StageCommand "merge" $null @()))
        Log  "  (add -Out ""<path>"" to the merge to write it elsewhere - ideally another drive)"
    } elseif ($tests.Count) {
        Log "The merge will NOT start on this result. Watch each candidate's join with the"
        Log "seam test (about 10 s each):"
        foreach ($o in $tests) { Log ("  " + (Get-StageCommand "seamtest" $o @())) }
        Log "then merge with the offset whose join you saw is clean, typed in place of SECONDS:"
        Log ("  " + (Get-StageCommand "merge" "SECONDS" @()))
        Log "  (menu: [2] asks which offset to test, [3] asks which offset to merge)"
    }
    Log "--------------------------------------------------------------"

    # ---- 5. verification stills --------------------------------------------------
    if ($best) {
        $n = 0
        foreach ($ar in ($best.anchors | Where-Object { $_.avail })) {
            $n++
            if (Write-Still $offsetOut $ar.t ("check{0}.jpg" -f $n) $fps) {
                Log ("  check{0}.jpg  VOD {1}s | master {2}s | difference (black = same picture)" -f $n, (F2 ($offsetOut + $ar.t)), (F2 $ar.t))
            }
        }
    }
    if (-not $mergeOk) {
        $n = 0
        foreach ($o in $tests) {
            $n++
            $at = Get-StillAnchor $o
            if ($null -ne $at -and (Write-Still $o $at ("cand{0}.jpg" -f $n) $fps)) {
                Log ("  cand{0}.jpg   offset {1}s: VOD {2}s | master {3}s | difference" -f $n, (F $o), (F2 ($o + $at)), (F2 $at))
            }
        }
    }

    # The merge preflight lives in the merge stage, where it can test the REAL
    # opening against the REAL master. Testing surrogate files here is exactly
    # what let the MOV failure slip through.

    # ---- 6. save the result ------------------------------------------------------
    # status= decides whether merge may start on its own; master_size/vod_size
    # let it refuse a result computed for other files.
    $candTxt = ($checked | ForEach-Object {
        $o = if ($_.verified -or $_.single) { $_.slot / $fps } else { $_.c }
        $kind = if ($_.verified) { "match" } elseif ($_.single) { "one" } else { "nomatch" }
        "{0}|{1}|{2}|{3}" -f (F $o), $kind, $_.hits, $_.src
    }) -join ";"
    $lines = @()
    if (-not [double]::IsNaN($offsetOut)) { $lines += ("offset=" + (F $offsetOut)) }
    # why an "unverified" match could be checked at one moment only (the menu says it)
    if ($status -eq "unverified") { $lines += ("lone=" + $singleC[0].lone) }
    $lines += @(
        ("status=" + $status),
        ("frames=" + $(if ($best) { FI $best.slot } else { "" })),
        ("fps=" + (F $fps)),
        ("pixel_distance=" + $(if ($best) { F $best.worst } else { "-1" })),
        ("audio_offset=" + $(if ($soundTop) { F $soundTop.t } else { "-1" })),
        ("audio_r=" + $(if ($soundTop) { F $soundTop.r } else { "0" })),
        ("audio_z=" + $(if ($soundTop) { F $soundTop.z } else { "0" })),
        ("candidates=" + $candTxt),
        ("master_size=" + (FI (Get-Item -LiteralPath $Master).Length)),
        ("vod_size=" + (FI (Get-Item -LiteralPath $Vod).Length))
    )
    $lines | Set-Content -LiteralPath $SyncFile -Encoding Ascii

    Log ("ANALYSIS DONE in {0}s (sound {1}s, pictures {2}s, frame check {3}s). Nothing was modified." -f `
         (F2 $clock.Elapsed.TotalSeconds), (F2 $tSound), (F2 ($tPicture - $tSound)), (F2 ($clock.Elapsed.TotalSeconds - $tPicture)))
    Finish 0
}

# ============================================================================
# STAGE: SEAMTEST
# ============================================================================
if ($Stage -eq "seamtest") {

    Log "=== SEAM TEST ==="
    Require-Inputs
    $offset = Read-Offset

    # The seam test is how an unconfirmed offset gets checked, so it never
    # refuses - it says so, and lets the user look.
    if (-not $OffsetText) {
        $st = Get-EffectiveStatus (Read-SyncFile)
        if ($st -ne "confirmed" -and $st -ne "video_only") {
            Log ("NOTE: this offset was NOT confirmed by the analysis ({0})." -f (Get-StatusText $st))
            Log  "      This clip is how you decide: if the join is clean, merge with this"
            Log  "      offset by typing it (-Offset, or when the menu asks)."
        }
    }

    $masterInfo = Probe $Master
    $vodInfo    = Probe $Vod
    if (-not $masterInfo -or -not $vodInfo) { Log "ERROR: could not probe the inputs."; Finish 1 }
    $v = Get-VideoStream $masterInfo
    $vodDur = [double]$vodInfo.format.duration
    Assert-SaneOffset $offset $vodDur

    # Check the user's own numbers first, so an error blames the right thing.
    if ($Pre -lt 0.1)  { Log ("ERROR: -Pre is {0}s. Give at least 0.1 s of VOD before the cut." -f (F $Pre)); Finish 1 }
    if ($Post -lt 0.1) { Log ("ERROR: -Post is {0}s. Give at least 0.1 s of master after the cut - with less there is no join to watch." -f (F $Post)); Finish 1 }

    # How much to show on each side of the cut, capped by what is actually
    # available: we cannot show more VOD than the recovered opening itself.
    $pre  = [Math]::Min($Pre, $offset)
    $post = $Post
    if ($pre -lt 0.1) {
        Log ("ERROR: the offset is only {0}s, so there is nothing to show before the cut." -f (F $offset))
        Finish 1
    }

    # The VOD half is cut on the SAME frame grid the merge uses: the merge's
    # opening is exactly nCut frames (offset = nCut / fps), so the clip shows
    # the last nPre of them and then the master's frame 0. Seeking straight to
    # "offset - pre" did not: a VOD frame can sit a few ms BEFORE its slot on
    # that grid (4 ms on a real Twitch VOD), an input seek drops frames before
    # the seek point, and the clip lost its first frame and showed its last one
    # twice - a hitch at the cut that the real merge does not have. Seeking a
    # whole frame earlier keeps the grid (a seek of N > 0 rebases timestamps by
    # exactly N) and the trims below take exactly the frames the merge uses.
    $rq     = ([string]$v.r_frame_rate) -split '/'
    $fr     = [double]$rq[0] / [double]$rq[1]
    $nCut   = [long][Math]::Round($offset * $fr)
    $nPre   = [long][Math]::Round($pre * $fr)
    if ($nPre -gt $nCut) { $nPre = $nCut }
    $nSeek  = [Math]::Max(0L, $nCut - $nPre - 1)
    $seekAt = $nSeek / $fr
    $j0     = $nCut - $nPre - $nSeek                   # the first frame to show, counted from the seek point
    $pre    = $nPre / $fr                              # whole frames, so video and sound end together
    $testOut = if ($Out) { $OutFile } else { Join-Path $ExportDir "seam_test.mp4" }
    $tDir = [System.IO.Path]::GetDirectoryName($testOut)
    if ($tDir -and -not (Test-Path -LiteralPath $tDir)) { New-Item -ItemType Directory -Force -Path $tDir | Out-Null }

    # Invariant display: these numbers get typed back in (CONSTRAINT 11).
    Log ("Offset in use: {0}s" -f (F $offset))
    Log ("Building a {0}s clip: {1}s of VOD, then the cut, then {2}s of the master." -f (F2 ($pre + $post)), (F2 $pre), (F2 $post))
    Log ("The cut lands at exactly {0}s into the clip." -f (F2 $pre))

    $vw = FI $v.width; $vh = FI $v.height; $rate = $v.r_frame_rate
    $fpost = F $post
    # Video and sound are cut at the same two instants: frames j0 .. j0+nPre-1
    # and the sound under them. After the fps filter the trim filter rounds its
    # bounds to whole frames (the link's time base is 1/fps), so the exact frame
    # times are the right bounds - a bound half a frame early was rounded DOWN
    # and dropped the last frame.
    $aA = F ($j0 / $fr); $aB = F (($j0 + $nPre) / $fr)
    $vA = $aA;           $vB = $aB

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
    $fc = "[0:v]scale=${vw}:${vh},fps=$rate,setsar=1,format=yuv420p,trim=start=${vA}:end=${vB},setpts=PTS-STARTPTS[v0];" +
          "[1:v]scale=${vw}:${vh},fps=$rate,setsar=1,format=yuv420p,trim=0:${fpost},setpts=PTS-STARTPTS[v1];" +
          "[0:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=start=${aA}:end=${aB},asetpts=PTS-STARTPTS[a0];" +
          "[1:a]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,apad,atrim=0:${fpost},asetpts=PTS-STARTPTS[a1];" +
          "[v0][a0][v1][a1]concat=n=2:v=1:a=1[v][a]"

    $ok = FF (@("-y", "-hide_banner", "-loglevel", "error") + $TsFix +
              @("-ss", (F $seekAt), "-t", (F (($j0 + $nPre + 2) / $fr)), "-i", $Vod,
                "-ss", "0", "-t", (F $post), "-i", $Master,
                "-filter_complex", $fc, "-map", "[v]", "-map", "[a]",
                # No chapters or data tracks from the VOD: a Twitch VOD's single
                # chapter spans the whole VOD and made this 10 s clip show an
                # 85 s timeline in players.
                "-map_chapters", "-1", "-dn", "-sn",
                "-c:v", "libx264", "-crf", "20", "-preset", "veryfast",
                "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart",
                $testOut)) "seam test clip"

    # The clip must be exactly as long as asked, in every track.
    if ($ok -and (Test-Path -LiteralPath $testOut)) {
        $ci = Probe $testOut
        $want = $pre + $post
        $longest = 0.0
        if ($ci) {
            $longest = [double]$ci.format.duration
            foreach ($s in $ci.streams) { if ($s.duration -and [double]$s.duration -gt $longest) { $longest = [double]$s.duration } }
        }
        if (-not $ci -or $longest -gt $want + 0.5 -or $longest -lt $want - 0.5) {
            Log ("ERROR: the test clip came out {0}s long instead of {1}s. Please report this." -f (F2 $longest), (F2 $want))
            Finish 1
        }
    }

    if ($ok -and (Test-Path -LiteralPath $testOut)) {
        Log ("OK -> {0}  ({1:N0} MB)" -f $testOut, ((Get-Item $testOut).Length / 1MB))
        Log ""
        Log ("WHAT TO LOOK FOR, at {0}s into the clip:" -f (F2 $pre))
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
    Require-Inputs                          # first, so the lines below name the files in use
    Log ("Master: {0}" -f $Master)
    Log ("VOD   : {0}" -f $Vod)
    Log ("Output: {0}" -f $OutFile)
    $offset = Read-Offset
    Assert-MergeAllowed $offset "merge"

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
        Log '       vodpatch.bat merge "D:\somewhere\merged.mp4"'
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
    Assert-SameClock $segment $masterInfo

    $list = Join-Path $WorkDir "concat_list.txt"
    Write-ConcatList $list $segment $Master

    # ---- 3. preflight: the exact command, stopped by SIZE not by time -------
    $headBytes = [double](Get-Item -LiteralPath $segment).Length
    if (-not (Invoke-Preflight $list $offset $headBytes $masterRate $OutFile)) {
        Log "PREFLIGHT FAILED - stopping before writing the whole file."
        Log "Your originals are untouched. See the log above, and try the fallback route ([4] in the menu)."
        Finish 1
    }

    Log "Joining by stream copy - the master is copied byte for byte, never re-encoded."
    if (-not (Invoke-FinalJoin $list $OutFile "final join")) { Finish 1 }
    Assert-FinalLength $OutFile $segment $masterInfo

    Log "Checking the seam for decode errors..."
    $global:LASTEXITCODE = 0
    # CONSTRAINT 4 -- rawvideo sink, not "-f null".
    $errs = & $ffmpeg -hide_banner -v error -ss (F ([Math]::Max(0.0, $offset - 3))) -t 8 -i $OutFile -map 0:v:0 -f rawvideo -pix_fmt gray -y NUL 2>&1 | Out-String
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
    Assert-MergeAllowed $offset "stripmerge"

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
    $strippedInfo = Probe $stripped
    if (-not $strippedInfo) { Log "ERROR: the timecode-free copy does not probe."; Finish 1 }
    Assert-SameClock $rawSeg $strippedInfo
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

    Assert-FinalLength $OutFile $rawSeg $strippedInfo
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
    Log ("Work  : {0}" -f $WorkDir)
    Log ("Out   : {0}" -f $OutFile)

    foreach ($pair in @(@("Root", $Root), @("Work", $WorkDir), @("Out", [System.IO.Path]::GetDirectoryName($OutFile)))) {
        $f = Get-FreeBytes $pair[1]
        if ($f -ge 0) { Log ("Free at {0,-5}: {1,8:N1} GB  ({2})" -f $pair[0], ($f/1GB), $pair[1]) }
        else          { Log ("Free at {0,-5}: unknown        ({1})" -f $pair[0], $pair[1]) }
    }

    Require-Inputs                          # before naming the files: it may pick them by size
    Log ("Master: {0}" -f $Master)
    Log ("VOD   : {0}" -f $Vod)
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
        Log "No analysis result yet. To run it:"
        Log ("   " + (Get-StageCommand "analyze" $null @()))
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
                      "-Work",   (ArgPath $WorkDir))
        # Pass a recording only if it exists or the user typed it. Passing the
        # default name of a missing file would make the stage report it as a
        # path the user typed ("this file does not exist").
        if ($MasterGiven -or (Test-Path -LiteralPath $Master)) { $callArgs += @("-Master", (ArgPath $Master)) }
        if ($VodGiven    -or (Test-Path -LiteralPath $Vod))    { $callArgs += @("-Vod",    (ArgPath $Vod)) }
        $callArgs += $extra
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
    if (Test-ShouldGuess) {
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
        $s = @{ offset = $null; status = $null; ran = $false; seam = $null; lone = $null }
        if (Test-Path -LiteralPath $SyncFile) {
            $s.ran = $true
            $cfg = Read-SyncFile
            $tmp = 0.0
            if ($cfg.ContainsKey("offset") -and
                [double]::TryParse($cfg["offset"], [System.Globalization.NumberStyles]::Float,
                                   [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tmp)) { $s.offset = $tmp }
            # legacy / other_files / the verdict - the same view the merge gate has
            $s.status = Get-EffectiveStatus $cfg
            $s.lone   = $cfg["lone"]
        }
        $seamFile = Join-Path $ExportDir "seam_test.mp4"
        if (Test-Path -LiteralPath $seamFile) { $s.seam = (Get-Item -LiteralPath $seamFile).LastWriteTime }
        return $s
    }

    # Only these two verdicts let the merge start without the user typing an offset.
    function Test-Confirmed($st) { return ($st.status -eq "confirmed" -or $st.status -eq "video_only") }

    # Ask for a number of seconds. Enter returns $null ("keep the default" or
    # "cancel", depending on the caller). Anything unreadable, or below $min,
    # asks AGAIN: a typo must never quietly become some other value - it used to
    # fall back to the saved offset without a word.
    function Read-OffsetFromUser([string]$prompt, [double]$min = $MinOffset) {
        while ($true) {
            Write-Host -NoNewline $prompt
            $raw = $null
            try { $raw = Read-Host } catch { return $null }
            if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
            $o = ConvertTo-Seconds $raw                                # CONSTRAINT 11
            if ($null -eq $o) {
                Write-Host ("  '{0}' is not a positive number of seconds - try again, or press Enter." -f $raw) -ForegroundColor Red
                continue
            }
            if ($o -lt $min) {
                Write-Host ("  it must be at least {0} s - try again, or press Enter." -f (F $min)) -ForegroundColor Red
                continue
            }
            return $o
        }
    }

    # [3] and [4]: on an unconfirmed verdict, the offset must be the one the
    # user watched in the seam test and typed - never picked for them.
    function Invoke-MergeChoice([string]$stageName, $st, [string]$destPath) {
        $ex = @("-Out", $destPath)
        if (-not (Test-Confirmed $st)) {
            Write-Host ""
            if (-not $st.ran) {
                Write-Host "  No analysis has been run yet. Type an offset you already know, or press"
                Write-Host "  Enter to cancel and run [1] first."
            } elseif ($st.status -eq "legacy") {
                Write-Host "  The saved analysis comes from an older version of vodpatch. Run [1] again,"
                Write-Host "  or type an offset you already checked with the seam test. Enter cancels."
            } elseif ($st.status -eq "other_files") {
                Write-Host "  The saved analysis was computed for other files. Run [1] again, or type"
                Write-Host "  an offset you already checked with the seam test. Enter cancels."
            } elseif ($st.status -eq "nothing_missing") {
                Write-Host "  Nothing to merge: the analysis found that the local recording already"
                Write-Host "  starts at the VOD's start. If you know otherwise, type an offset you"
                Write-Host "  checked with the seam test. Enter cancels."
            } else {
                Write-Host "  The analysis did not confirm an offset. Type the offset whose seam test"
                Write-Host "  you watched and found clean, or press Enter to cancel."
            }
            $ov = Read-OffsetFromUser "  Offset: "
            if ($null -eq $ov) {
                Write-Host "  Cancelled." -ForegroundColor DarkGray
                Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                [void](Read-Host)
                return
            }
            $ex += @("-Offset", (F $ov))
        }
        Invoke-Stage $stageName $ex
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
            if ($MasterGiven -and -not (Test-Path -LiteralPath $Master)) {
                Write-Host ("    -Master does not exist: {0}" -f $Master) -ForegroundColor Red
            }
            if ($VodGiven -and -not (Test-Path -LiteralPath $Vod)) {
                Write-Host ("    -Vod does not exist:    {0}" -f $Vod) -ForegroundColor Red
            }
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
        Write-Host "  [1] Analyze        " -NoNewline
        if (-not $st.ran) {
            Write-Host "not run" -ForegroundColor Yellow
        } else {
            switch ($st.status) {
                "confirmed"  { Write-Host ("offset {0} s - confirmed by picture and sound" -f (F $st.offset)) -ForegroundColor Green }
                "video_only" { Write-Host ("offset {0} s - confirmed by picture" -f (F $st.offset)) -ForegroundColor Green }
                "conflict"   { Write-Host "NOT CONFIRMED: picture and sound disagree - see analyze_log.txt" -ForegroundColor Yellow }
                "ambiguous"  { Write-Host "NOT CONFIRMED: matches in more than one place - see analyze_log.txt" -ForegroundColor Yellow }
                "unverified" {
                    $why1 = if ($st.lone -eq "master") { "the master's opening has one distinctive moment" } else { "short overlap" }
                    Write-Host ("NOT CONFIRMED: matched at one moment only ({0}) - see analyze_log.txt" -f $why1) -ForegroundColor Yellow
                }
                "audio_only" { Write-Host "NOT CONFIRMED: only the sound matched - see analyze_log.txt" -ForegroundColor Yellow }
                "nothing_missing" { Write-Host "NOTHING MISSING: the master already starts at the VOD's start" -ForegroundColor Green }
                "none"       { Write-Host "NO MATCH: see analyze_log.txt for why" -ForegroundColor Red }
                "other_files" { Write-Host "result is for other files - run it again" -ForegroundColor Yellow }
                default      { Write-Host "result from an older version - run it again" -ForegroundColor Yellow }
            }
        }
        # [2] seam test
        Write-Host "  [2] Seam test      " -NoNewline
        if ($null -eq $st.seam) { Write-Host "not run" -ForegroundColor Yellow }
        else { Write-Host ("seam_test.mp4, {0}" -f (Show-Age $st.seam)) -ForegroundColor Green }
        # [3] merge
        Write-Host "  [3] Merge          " -NoNewline
        if (-not $inputsOk)                 { Write-Host "choose the source files first - press [F]" -ForegroundColor DarkGray }
        elseif (-not $st.ran)               { Write-Host "run the analysis first" -ForegroundColor DarkGray }
        elseif ($st.status -eq "nothing_missing") { Write-Host "nothing to merge - the master is complete" -ForegroundColor DarkGray }
        elseif (-not $spaceOk)              { Write-Host "blocked: not enough space at the destination" -ForegroundColor Red }
        elseif (-not (Test-Confirmed $st))  { Write-Host "will ask for the offset you checked with [2]" -ForegroundColor Yellow }
        elseif ($null -eq $st.seam)         { Write-Host "ready (watching the seam test first is wise)" -ForegroundColor Green }
        else                                { Write-Host "ready" -ForegroundColor Green }

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
                # A saved offset the seam test would refuse is not offered.
                $useSaved = ($null -ne $st.offset -and $st.offset -ge $MinOffset)
                $def = if ($useSaved) { F $st.offset } else { "none - type one" }
                $ov  = Read-OffsetFromUser ("  Offset to test [{0}]: " -f $def)
                if ($null -eq $ov -and -not $useSaved) {
                    Write-Host "  Cancelled - there is no saved offset to test." -ForegroundColor DarkGray
                    Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                    [void](Read-Host)
                } else {
                    # Every typed number goes through ConvertTo-Seconds (CONSTRAINT 11):
                    # "12,5" -as [double] is 125 on this kind of machine.
                    $p1 = Read-OffsetFromUser "  Seconds of VOD before the cut [5]: "
                    $p2 = Read-OffsetFromUser "  Seconds of master after it    [5]: "
                    $ex = @()
                    if ($null -ne $ov) { $ex += @("-Offset", (F $ov)) }
                    if ($null -ne $p1) { $ex += @("-Pre",    (F $p1)) }
                    if ($null -ne $p2) { $ex += @("-Post",   (F $p2)) }
                    Invoke-Stage "seamtest" $ex
                }
            }
            "3" {
                if (-not $spaceOk) {
                    Write-Host ""
                    Write-Host "  The destination does not have room. Press [D] to change it first." -ForegroundColor Red
                    Write-Host "  -- press Enter --" -ForegroundColor DarkGray
                    [void](Read-Host)
                } else {
                    Invoke-MergeChoice "merge" $st $dest
                }
            }
            "4" { Invoke-MergeChoice "stripmerge" $st $dest }
            "5" { Invoke-Stage "doctor" @("-Out", $dest) }
            "6" {
                Write-Host ""
                Write-Host "  This removes the re-encoded head, the concat list and the analysis"
                Write-Host "  temporaries. It KEEPS sync_result.txt and merge_work\verify\."
                Write-Host -NoNewline "  Type YES to confirm: "
                if ((Read-Host) -eq "YES") {
                    foreach ($n in @("opening.mp4", "opening_tc.mov", "opening_stamp.txt",
                                     "concat_list.txt", "progress.txt", "probe_raw.mp4", "probe_tc.mov",
                                     "keyframes_vod.txt", "keyframes_vod.gray")) {
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
                $pickOldMaster = $Master
                Write-Host ("  Master (the good local recording) [{0}]" -f [System.IO.Path]::GetFileName($Master))
                Write-Host -NoNewline "    > "
                $pick = Resolve-Pick (Read-Host) $near
                if ($pick) {
                    if (Test-Path -LiteralPath $pick -PathType Leaf) { $Master = $pick; $autoPicked = $false }
                    else { Write-Host "    not a file: $pick" -ForegroundColor Red }
                }

                Write-Host ("  VOD (the stream recording) [{0}]" -f [System.IO.Path]::GetFileName($Vod))
                Write-Host -NoNewline "    > "
                $pick = Resolve-Pick (Read-Host) $near
                if ($pick) {
                    if (Test-Path -LiteralPath $pick -PathType Leaf) { $Vod = $pick; $autoPicked = $false }
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

                    # Move only when a DIFFERENT master was picked and no -Work was
                    # typed. Pressing Enter at both prompts used to move the work
                    # folder anyway, hiding a confirmed analysis behind "not run".
                    # Test-UsableWorkDir creates the folder, so it is tested last.
                    $mDir = Split-Path -Parent $Master
                    if (-not $Work -and $Master -ne $pickOldMaster -and $mDir -and
                        (Test-UsableWorkDir (Join-Path $mDir "merge_work"))) {
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
