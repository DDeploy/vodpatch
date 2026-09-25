# vodpatch

Recover the missing beginning of a local recording from a stream VOD, and put
it back on the front — without re-encoding the master.

<img width="1115" height="628" alt="image" src="https://github.com/user-attachments/assets/9db1b2ad-01ee-4f5c-9414-e65c88e73b7e" />


## Quick start

1. Download the ZIP (green **Code** button → **Download ZIP**) and extract it
   **anywhere** — a USB stick, your desktop, the folder your footage is in.
   Nothing is installed and nothing is written outside that folder.
2. If Windows marks the files as blocked, right-click `vodpatch.ps1` →
   **Properties** → tick **Unblock**. (Downloaded ZIPs sometimes carry this.)
3. Make sure ffmpeg is available — either [installed](#requirements), or just
   drop `ffmpeg.exe` and `ffprobe.exe` into a `bin` folder next to the script.
4. **Double-click `vodpatch.bat`.**

That's it. The menu finds your two recordings, tells you what it knows about
them, and walks you through it. If your files are somewhere else, press `[F]`
and point at them.

## The problem

You recorded a session twice:

* **locally**, on a capture deck or recorder — high bitrate, the good master;
* **on a streaming platform** — a compressed VOD, but complete.

The local recorder was started late, so the master is missing its first
minutes. The VOD has them. You want one file: the recovered opening followed by
the untouched master, joined at exactly the right frame.

`vodpatch` finds the offset between the two recordings automatically,
re-encodes **only** the missing opening to match the master, and joins the two
with ffmpeg's concat demuxer so the master is copied byte for byte. A 56 GB
master is never re-encoded and never modified.

## Requirements

* **Windows PowerShell 5.1** (the one that ships with Windows — not PowerShell 7)
* **ffmpeg and ffprobe on `PATH`**, e.g. `winget install Gyan.FFmpeg`, or a
  build from <https://www.gyan.dev/ffmpeg/builds/>
* That ffmpeg build must include **libx264**, which in practice means a
  **GPL-enabled** build — its configuration line shows `--enable-gpl` and
  `--enable-libx264`. The recovered opening is encoded with libx264, and
  libx264 is GPL-licensed, so an LGPL-only build does not have it and the merge
  stage fails with `Unknown encoder 'libx264'`. `vodpatch.bat doctor` checks this and
  says so.

Nothing else. No modules, no Python, no downloads at runtime.

If ffmpeg is not on `PATH`, the script also looks in `C:\ffmpeg\bin`,
`%ProgramFiles%\ffmpeg\bin` and the WinGet links folder.

ffmpeg is **not** distributed with this project and must not be committed to
it — see [Third-party software](#third-party-software).

## Portable use

There is nothing to install and no fixed location. Extract the folder wherever
you want and run it from there — everything resolves relative to the script,
so it works from a USB stick, a desktop folder, or straight onto the card
beside your footage. Folder names with spaces, accents and parentheses are
fine, including the `vodpatch-main (1)` a second download gives you.

**Bundling ffmpeg.** If you drop `ffmpeg.exe` and `ffprobe.exe` next to the
script, or into `bin\` or `ffmpeg\bin\`, those are used in preference to
anything installed system-wide. That makes the whole thing self-contained:

```
vodpatch\
  vodpatch.bat
  vodpatch.ps1
  bin\
    ffmpeg.exe
    ffprobe.exe
```

Do not commit those binaries if you fork this — see
[Third-party software](#third-party-software).

**Finding your recordings.** Put both files in the folder and the script works
out which is which: the two largest video files, with the **bigger one treated
as the local recording** and the smaller as the VOD. That is the right way
round, because the local capture is the high-bitrate one. Filenames do not
matter — any container it can read will do (`.mp4`, `.mov`, `.mkv`, `.mxf`,
`.m2ts` and the rest).

It always prints which two it chose, so you can see if it guessed wrong. To
override: press `[F]` in the menu and pick from the list it shows, or pass
`-Vod` and `-Master` explicitly. Relative paths resolve against wherever you
launched from.

**Where the results go.** Finished files land in an `exported` folder next to
the script — `full_recording.mp4` from a merge, `seam_test.mp4` from a seam
test — so a result is never mistaken for one of your sources. `-Out` sends the
merge anywhere you like, and you normally should: see the speed warning above.

**If the folder is read-only** — unzipped into Program Files, or sitting on a
network share, which Windows will not accept as a working directory — the work
files and the log go to your temp folder instead, and the script says so
rather than failing somewhere deep in a filter graph.

## Usage

**Double-click `vodpatch.bat`.** It opens a menu that shows what it knows
about your files, which steps have already run, and — before you start
anything — whether the destination has room:

```
  vodpatch                                          GPL v3
  ----------------------------------------------------------
  Folder   F:\
  VOD      stream_vod.mp4             395.0 s    0.36 GB
  Master   CAM_A_0042.mov           9828.2 s   52.67 GB
           streams: video, data, audio
           picked by size - press [F] if that is the wrong way round

  Output   D:\exported\full_recording.mp4
           27.7 GB free - NOT ENOUGH, needs about 56.3 GB

  [1] Analyze        offset 170.353517 s - confirmed by picture and sound
  [2] Seam test      seam_test.mp4, 12 min ago
  [3] Merge          blocked: not enough space at the destination
  [4] Merge - fallback route (strip the timecode track)
  [5] Doctor - diagnostics for a bug report
  [6] Clean the working files

  [F] Choose the source files
  [D] Change the output destination
  [Q] Quit
```

Work through 1 → 2 → 3 in order. Each step runs in its own process and writes
a log next to the script, so a step that fails drops you back to the menu
instead of closing the window.

If you would rather not use the menu, give the launcher a stage and it goes
straight there:

```
vodpatch.bat analyze
vodpatch.bat seamtest
vodpatch.bat merge "D:\record\full_stream.mp4"
vodpatch.bat doctor
```

Anything beyond that — different filenames, an audio shift, a manual offset —
goes to the script directly; see [Options](#options).

The three steps, in order:

### 1. Analyze — find the offset

Read-only. Neither source file is written to at any point.

```
vodpatch.bat analyze
powershell -File vodpatch.ps1 -Stage analyze -Vod "D:\vod.mp4" -Master "D:\master.mp4"
```

It reports something like this (a real run on a near-static interview):

```
Step 1/3 - sound: the loudness of the master's first 90 s, searched through the whole VOD...
  sound match 1: VOD 111.50s  r=0.831  z=13.23   <- strong
  sound match 2: VOD 166.20s  r=0.202  z=3.25
Step 2/3 - pictures: every VOD keyframe against the master's first 60 s...
  picture match 1: VOD 111.40s  distance 0.98/255 over 30 keyframes
  picture match 2: VOD 131.30s  distance 27.35/255 over 31 keyframes
Step 3/3 - frame check: each candidate, frame by frame, at 3 distinctive moments...
  111.50s (sound+picture): 23.00s -> 6688 (0.31);  39.00s -> 6688 (0.29);  34.00s -> 6688 (0.28)  => MATCH, frame 6688
  166.20s (sound): 23.00s -> 10029 (44.28) no;  ...  => no match
RESULT: CONFIRMED. The picture matches frame for frame at separate moments,
        and the sound independently lands 0.03s away.
OFFSET: 111.466667 s  = 6688 frames at 60/1 fps = 1 min 51.47 s of recovered footage
```

How it works. Two cheap searches each **suggest** up to three candidate
offsets; neither decides anything on its own:

1. **Sound** — the loudness of the master's opening, correlated along the whole
   VOD. It is about a hundred times cheaper than reading pictures, and it copes
   with a VOD that ends shortly after the master starts.
2. **Pictures** — every VOD keyframe compared with the master's opening. Only
   keyframes are decoded, which is what keeps a six-hour VOD down to minutes.

Then every candidate goes through a **frame check**: at three moments of the
master that look different from what surrounds them, the master's picture is
slid over the VOD frame by frame. A candidate is accepted only if at least two
of those moments land on **the same frame**. A wrong candidate cannot do that —
across 78 wrong candidates in testing, not one managed it. A moment that barely
changes (a still "starting soon" screen) is never used: it would match every
frame of that still equally well, so it proves nothing.

The heavy inner loops are inline C# compiled with `Add-Type`, because
PowerShell loops are far too slow for this.

**The verdict** is one of:

| status | meaning | merge |
|---|---|---|
| `confirmed` | the picture matches frame for frame, and the sound agrees | starts |
| `video_only` | the picture matches frame for frame; the sound could not help (silent, muted, different) | starts |
| `conflict` | the picture matches, but the sound points somewhere else | blocked |
| `ambiguous` | the picture matches in more than one place (a replay, a loop), or both at the VOD's very start and somewhere later, or a confirmed place is contradicted by a close match at one moment elsewhere | blocked |
| `unverified` | the picture matches, but only one moment could be checked: the VOD ends too soon after the master starts, or the master's first minute has only one moment that changes enough to pin down a frame | blocked |
| `audio_only` | only the sound matched; the picture could not confirm it | blocked |
| `nothing_missing` | the master already starts at (or before) the VOD's first frame, give or take 0.1 s: there is no opening to recover | nothing to merge |
| `none` | no match. If both searches ran, the files probably do not overlap; if one could not run (no audio, too few keyframes, too short, a master that opens on a still picture for a whole minute), the log says so and it proves nothing | nothing to merge |

A result saved for **other files**, or by an **older version** of vodpatch, is
treated as unconfirmed everywhere — in the menu, in the seam test's warning, and
at the merge — until the analysis is run again.

When it is not confirmed, the tool does **not** guess. It prints the exact
seam-test command for each candidate, so you can watch each join in about 10
seconds and then merge with the one you saw is clean, by typing it (`-Offset`,
or when the menu asks). The seam test itself is never blocked — it is how you
decide.

It also writes verification stills to `merge_work\verify\`: VOD, master, and
their difference, where **black means the same picture**. Look at them.

The result is saved to `merge_work\sync_result.txt`.

### 2. Seam test — watch the join before committing

```
vodpatch.bat seamtest
powershell -File vodpatch.ps1 -Stage seamtest -Pre 150 -Post 150
```

Renders a short clip centred on the cut, to `exported\seam_test.mp4`: 5 seconds of
VOD, the cut, then 5 seconds of the master (`-Pre` / `-Post` show more, as in
the second line above). The VOD half is cut on the same frames the merge will
use, so the clip shows the join exactly as the final file will. Watch it. What
you want to see at the join:

* the action flows straight through — no jump back, no skipped moment, no
  frozen frame;
* the picture visibly **sharpens** at the cut. That is correct: the first half
  is the compressed VOD, the second half is your clean master;
* nothing repeats in the audio. If you hear a word or a sound played twice, the
  VOD's own audio is offset against its own video — see `-AudioShift` below.

### 3. Merge — build the final file

```
vodpatch.bat merge "D:\record\full_stream.mp4"
```

**Pass an output path on a different physical drive from the master.** Reading
and writing the same removable card at once is pathologically slow — ~460 KB/s
was measured on a CFast card, against ~155 MB/s writing to an internal SSD.

The merge:

1. re-encodes the recovered opening from the VOD, matching the master's codec,
   resolution, frame rate, pixel format, colour metadata, audio format and
   **clock** (time base) — exactly as many frames as the offset covers, and
   only the VOD's picture and sound (no data tracks, no chapters);
2. gives it the master's **stream layout** (see
   [The timecode track](#the-timecode-track)), and checks that both pieces
   count time in the same units;
3. runs a **preflight**: the real join command, stopped by bytes written, to
   the real destination, asserting that it actually crossed the seam, that its
   picture and sound are the same length and plausible, and that it decodes
   cleanly;
4. joins the two by stream copy, writing to a `.part` file that is renamed only
   on success;
5. **checks the finished file's length** against the opening plus the master,
   track by track. A result of the wrong length is renamed `*.broken.mp4` and
   the merge fails — it is never reported as a success;
6. verifies the seam and writes stills of it to `merge_work\verify\`.

While it runs, **the output file's size will not change in Explorer.** Windows
does not refresh size or mtime while ffmpeg holds the file open. Watch
`merge_work\progress.txt` instead — the `out_time` line is the live position.

### The other menu items

| item | what it does |
| ---- | ------------ |
| **[4] Fallback route** | Strips the timecode track instead of adding one — see [The timecode track](#the-timecode-track). Only needed if [3] stops and tells you to use it. |
| **[5] Doctor** | Prints tool versions and build flags, your locale, free space, the full stream inventory of both inputs, the saved offset and the state of any cached opening. Attach `doctor_log.txt` when reporting a problem. |
| **[6] Clean** | Removes the re-encoded head, the concat list and the analysis temporaries. Keeps `sync_result.txt` and `merge_work\verify\`. Asks for confirmation. |
| **[F] Source files** | Choose the master and the VOD. Lists the video files it can see so you can just type a number, or paste a path — dragging a file into the window works, quotes and all. It re-reads both files and moves the work folder next to the master. |
| **[D] Destination** | Changes where the merged file is written, and re-checks free space immediately. Give a folder and it appends a default filename. |

## Options

Every launcher is a thin wrapper around `vodpatch.ps1`. Call it directly for
anything the launchers do not expose:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\vodpatch.ps1 `
    -Stage merge -Vod "D:\vod.mp4" -Master "E:\CARD\master.mp4" `
    -Out "D:\out\full.mp4" -AudioShift -0.25
```

| parameter      | default                     | meaning                                              |
| -------------- | --------------------------- | ---------------------------------------------------- |
| `-Stage`       | `menu`                      | `menu`, `analyze`, `seamtest`, `merge`, `stripmerge`, `doctor` |
| `-Root`        | the script's folder         | where the sources are looked for                     |
| `-Vod`         | auto-detected               | the stream VOD (the smaller of the two)              |
| `-Master`      | auto-detected               | the local recording (the larger of the two)          |
| `-Out`         | `<Root>\exported\full_recording.mp4` | the final file                              |
| `-Work`        | `<Root>\merge_work`         | scratch folder                                       |
| `-Strip`       | next to `-Out`              | `stripmerge`'s timecode-free copy of the master      |
| `-Pre` `-Post` | `5` `5`                     | `seamtest`: seconds shown each side of the cut       |
| `-AudioShift`  | `0`                         | shift the opening's audio against its video, in seconds. Positive delays the audio, negative advances it. Applied to the recovered opening only. |
| `-Offset`      | from `sync_result.txt`      | use this offset instead of the analysis's. Typing it is you taking responsibility: the merge then starts even on an unconfirmed verdict. |
| `-Force`       | off                         | rebuild the cached opening even if it looks reusable |

Numbers can be written with a point **or a comma** — `12.5` and `12,5` both
mean twelve and a half seconds — through `vodpatch.bat`, `cmd.exe` or the menu.
From a PowerShell prompt use a point: there, `12,5` is a list before the script
ever sees it. Anything else (`1e2`, `1,234.5`) is refused rather than guessed at.

Relative paths are resolved against the directory you launched from, not
against the work folder.

## The timecode track

This is the one that will bite you, so it gets its own section.

**The concat demuxer pairs streams by index, not by type.** A Blackmagic master
is:

```
#0 video   h264
#1 data    tmcd      <- timecode
#2 audio   pcm_s24le
```

A plain re-encoded opening is `#0 video, #1 audio`. Concatenate them and at the
junction ffmpeg starts feeding the master's **4-byte timecode packets into the
audio track**. A `pcm_s24le` stereo sample is 6 bytes, so ffmpeg computes
4 / 6 = 0 samples and dies:

```
fatal error, input packet contains no samples
Conversion failed!    (AVERROR_PATCHWELCOME, -1163346256)
```

`-dn` on the output does **not** help: the mis-pairing happens on input.

The fix is to give the opening the same stream layout as the master, by copying
the master's (tiny) timecode track into it at the same index. MP4 refuses to
copy a `tmcd` track — `Could not find tag for codec none` — so it has to go into
a **MOV**, with `-write_tmcd 0` to suppress the second, automatic timecode track
that `movenc` otherwise appends. A layout with extra **trailing** streams is
fine: pairing starts at index 0, so only the leading streams have to line up.

The script tries five construction methods on a 5-second sample and picks the
first one whose layout matches.

**Do not "fix" this by switching the output to Matroska.** MKV has no
equivalent check. It would not error — it would silently write timecode bytes
into your audio track.

If no method works, use the fallback route (menu item 4). It goes the other way: it makes a
copy of the master **without** its timecode track, so both files are plain
video+audio and nothing can be mis-paired. Everything stays a stream copy, so
it is still lossless, but the master is written twice — budget one extra full
pass and enough free space for both files.

## Troubleshooting

### `Application provided invalid, non monotonically increasing dts`

A VOD stitched together from `.ts` segments routinely carries duplicate DTS.
Every input read of the VOD therefore passes `-fflags +genpts+igndts`, and no
analysis pass ever writes to `-f null` — the null muxer enforces strictly
increasing timestamps and aborts on exactly this. Analysis passes write to
`-f rawvideo ... -y NUL` or `-f s16le ... -y NUL` instead. If you add a pass,
follow the same rule.

### The script dies on a harmless ffmpeg warning

`$ErrorActionPreference` is deliberately `Continue`, never `Stop`. With `Stop`,
PowerShell turns **every** line ffmpeg writes to stderr into a fatal
terminating error, including warnings. Every ffmpeg call goes through one
wrapper that checks `$LASTEXITCODE` explicitly. Do not change this.

### ffmpeg misparses a number, or a duration comes out wrong

On a non-English Windows, `147.5` stringifies as `"147,5"` through PowerShell's
`-f` operator or a bare `.ToString()`, and ffmpeg misparses it silently. Every
number handed to ffmpeg goes through the `F()` (fractional) or `FI()` (integer)
helper, which format with the invariant culture. Use them for **every** numeric
argument you add. `vodpatch.bat doctor` prints a check of this.

### `Unable to find a suitable output format` / the filter graph will not parse

Never put an absolute Windows path inside an ffmpeg **filter option string**.
In `metadata=print:file=D:\x\y.txt` the drive-letter colon is read as an option
separator. The script `Push-Location`s into the work folder and uses bare
relative filenames for filter outputs. Ordinary `-i` and output arguments are
fine with absolute paths.

### `No such file or directory` on a path that exists

The concat list must be **UTF-8 without a BOM**. Both obvious alternatives are
broken, and both were verified:

| encoding                         | result                                   |
| -------------------------------- | ---------------------------------------- |
| `Out-File -Encoding ascii`       | `Impossible to open '…\Vid?os …'` — every accented character becomes `?` |
| `Out-File -Encoding utf8` (5.1)  | `Line 1: unknown keyword '\ufefffile'` — PowerShell 5.1 writes a BOM |
| `File.WriteAllLines(…, UTF8Encoding($false))` | works |

Apostrophes in paths are handled too: inside single quotes ffmpeg treats
everything literally except the quote itself, which is escaped as `'\''`.
Backslashes are literal, so Windows paths need no special handling.

### The preflight passes but the real merge fails hours later

It should not, and that is the whole point of how the preflight is built. It
runs the **real** command — same options, same destination — bounded by bytes
written (`-fs`) rather than by `-ss`/`-t`. An earlier version bounded it by
time, which perturbed exactly the behaviour under test and reported two false
PASSes, letting two multi-hour failures through. The byte budget is derived
from the master's measured bitrate so that it always reaches well past the
seam, and the preflight asserts that the test output really did cross the seam
before declaring success. Keep both properties if you touch it.

### The output file's size never changes

Windows does not refresh a file's size or mtime while ffmpeg holds it open.
That is why the merge passes `-progress merge_work\progress.txt`. Read
`out_time` from there.

### It is crawling at a few hundred KB/s

You are reading and writing the same physical drive. Pass `-Out` (or an
the second argument to `vodpatch.bat merge`) pointing at a different drive. The script warns when
the output shares a drive with the master.

### `A parameter cannot be found`, or an argument list comes out mangled

`$args` is a reserved automatic variable in PowerShell. Never use it as a local
name. Note also that a *simple* function silently swallows unrecognised
arguments into `$args`, so `Log "at {0}s" -f $x` does not error — it just logs
the format string unformatted. Write `Log ("at {0}s" -f $x)`.

### An ffmpeg call failed and the log is useless

Log the **first** lines of a failed ffmpeg call, not just the last. The
informative message is always first; the tail is generic "task finished with
error code" noise. The `FF` wrapper logs the first six lines and then the last
three.

### An offset, audio shift or clip length comes out ten or a hundred times too big

On a French (or any comma-decimal) Windows, PowerShell reads a `[double]`
parameter with the *invariant* culture, where a comma is a **thousands**
separator. Measured: `-AudioShift -0,25` became −25, `-Offset 12,5` became 125,
`-Offset 111,467` became 111467. The 125 case is the dangerous one — it passes
every sanity check and silently builds the wrong file.

So `-Offset`, `-AudioShift`, `-Pre` and `-Post` are read as **text** and parsed
by `ConvertTo-Seconds`, which accepts a point or a comma and refuses anything
else. The menu's prompts go through it too — `"12,5" -as [double]` is also 125.
(CONSTRAINT 11.) The variables behind them are deliberately not called
`$Offset` etc.: PowerShell names are case-insensitive, so a stage's
`$offset = Read-Offset` would write straight into the parameter.

### The analysis takes minutes instead of seconds

A `byte[]` returned bare from a PowerShell function is **unrolled** into an
`object[]` of boxed bytes, and every C# call then converts it back — measured
133 s instead of 0.1 s on the master's 8 MB of frames. `Get-RawFrames` returns
`,$bytes` (note the comma) for this reason. The same copy-on-call behaviour
makes `[Array]::Sort(keys, items)` silently sort a copy, which is why sorting
goes through `[Sig]::Order`. (CONSTRAINT 12.)

### A number is silently rounded — or every high-bitrate merge fails preflight

`[Math]::Max(0, 134.458)` is **134**: with an integer first argument PowerShell
picks the `Int32` overload. Always write `[Math]::Max(0.0, $x)`. The old
detector had this bug in the seek that positioned its search window.

The same overload **throws** once the other argument no longer fits in 32 bits.
The preflight's `[Math]::Max(150MB, …)` did exactly that for any master above
about 215 MB/s (4K ProRes and similar): the margin came out empty, the test file
stopped right at the seam, and every merge failed its preflight. It now reads
`[Math]::Max([double]150MB, …)`. (CONSTRAINT 13.)

### The merged file is hours too long, and stutters when you scrub it

Every piece of a stream-copy join must count time in the **same units** (its
*time base*). The concat demuxer does not reconcile them. x264 picks its own
clock for the recovered opening — 1/15360 s at an integer 60 fps — while a
60 fps OBS recording counts in 1/60000 s, and the joined file's video track then
claimed **40 691 s instead of 10 417 s**: 60000 / 15360 = 3.906× too long,
playing in slow motion against the sound. (At 59.94 fps x264's default happens
to be 1/60000, which is why a 59.94 master never showed it.) The opening is now
encoded with the master's clock (`-video_track_timescale`); the merge refuses
to join pieces whose clocks differ; the preflight fails if picture and sound
disagree; and a finished file of the wrong length is renamed `*.broken.mp4`
instead of being reported as a success. If you merged with an older version,
merge again — the cached opening is rebuilt automatically. (CONSTRAINT 14.)

### The seam test is 10 seconds long but the player shows a much longer timeline

A Twitch VOD carries a **chapter** spanning the whole VOD, and ffmpeg copies
chapters by default. Cut out of the middle of the VOD, that chapter became a
track running 85 s past a 10 s clip, and players size the timeline to the
longest track. The seam test and the recovered opening now take only the VOD's
picture and sound (`-map_chapters -1 -dn`), and the seam test checks its own
length.

## Known limitations

* **Only tested against two real master / VOD combinations** — H.264 +
  `pcm_s24le` in MP4 at 1920×1080 59.94 with a `tmcd` timecode track, and H.264
  + AAC in MP4 at 1920×1080 60 with no timecode — plus synthetic variants of the
  second (overlay, 720p30, range mismatch, muted, mirrored, looped, a 30 s
  overlap), and 149 synthetic cases with known answers for the detector
  (facecam composites over a static layout, a calm talking head, stills,
  short overlaps). Other combinations should work but are untested.
* **Different frame rates between the two files** (e.g. a 59.94 master against a
  60 VOD) are not corrected for. The frame check may then only agree to within a
  frame or two and come out unconfirmed; the seam test decides.
* **No resume.** An interrupted merge restarts from zero. The recovered opening
  *is* cached and will not be re-encoded, as long as the offset and sources are
  unchanged.
* **You may hear a faint tick at the join.** Two different encodings of the
  same moment are butted together at a single sample, and their waveforms are
  never bit-identical, so there is a step. Measured on the real job, the step
  at the cut is about 4x a normal sample-to-sample change: audible as a small
  tick, not a dropout. Removing it would mean crossfading across the boundary,
  which means re-encoding the master's audio — the one thing this tool exists
  to avoid. If it bothers you, open the output in an editor and put a 20 ms
  audio crossfade on the join: a ten-second manual fix, once.

  Worth knowing what this is *not*. There is no silence gap in the merged
  output — the level runs continuously across the cut — and nothing repeats.
  If you hear a real dropout or a repeated word, that is a different problem:
  check that the two analyses agreed, and see `-AudioShift`.
* **Reading and writing the same removable card is pathologically slow.** Send
  the output to a different physical drive.

## Why the detector works the way it does

The first version correlated **motion energy** — how much each frame differs
from the one before. On a fast-moving gaming stream that worked well. On an
interview where three people stand and talk, it failed completely: motion was
flat, the correlation was noise (0.455 against a runner-up of 0.432), and it
picked an offset 67 seconds wrong. The sound, meanwhile, had the right answer
the whole time and was being ignored.

It also had a second, independent flaw. It slid a 90-second piece of the master
along the VOD and required it to fit entirely inside. On a 192-second VOD that
cannot reach any offset past 101 seconds — and the real one was 111.47. No
amount of signal quality would have fixed that.

Three lessons are built into the current design:

* **Candidates, then an independent check.** Sound and pictures only *suggest*;
  a separate frame-by-frame check decides. A wrong suggestion costs a few
  seconds of checking, never a wrong file.
* **Judge a match against the moment's own motion.** The obvious confidence
  measure — how much better the best match is than the runner-up — is useless
  on still footage, where every frame resembles every other: it sat at about
  1.35 whether the answer was right or wrong. A fixed distance limit is not
  enough either: on a facecam over a static layout a *wrong* frame also scores
  low (under 4/255), and two such moments once agreed on a wrong frame and
  started the merge 46 seconds off. So a moment counts only when its difference
  is small compared with how much that moment itself changes in a second — or
  is near-perfect outright (0.4/255 or less), which very calm footage needs.
  The VOD is first matched to the master's brightness and contrast, so a
  colour-range mismatch no longer inflates the difference (10.4 → 1.5/255).
  On 149 test cases with known answers this verified no wrong frame; the old
  fixed limit verified 10. A frozen picture is never used at all.
* **Keep absolute timestamps.** A VOD whose video track starts at 0.947 s while
  its audio starts at 0.020 s will fool any correlation that assumes both begin
  at zero. `analyze` prints each stream's start time so you can see it.

If a verdict says `conflict` and the seam test at the picture offset joins
cleanly but the voices in the recovered part are off, the VOD's own sound is out
of step with its picture: merge at the picture offset with the `-AudioShift`
value the analysis prints.

## Third-party software

This project drives **ffmpeg** and **ffprobe** as external programs. It does
not link against them, embed them, or ship them: it spawns them as separate
processes and talks to them over the command line. ffmpeg is a separate work
under its own licence (LGPL-2.1-or-later, or GPL when built with components
such as libx264 — which is the build this tool needs).

**Do not commit ffmpeg binaries to this repository.** Distributing ffmpeg
brings its own obligations, which for a GPL build include conveying the
corresponding source or a written offer for it. Requiring users to install
ffmpeg themselves avoids all of that. `.gitignore` blocks `*.exe` and `*.dll`
as a guardrail.

## License

Copyright (C) 2026 Deployer (https://github.com/DDeploy)

This program is free software: you can redistribute it and/or modify it under
the terms of the **GNU General Public License** as published by the Free
Software Foundation, either **version 3** of the License, or (at your option)
any later version.

This program is distributed in the hope that it will be useful, but **WITHOUT
ANY WARRANTY**; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.

The full text is in [LICENSE](LICENSE).

### What that means in practice

* You may use, study, modify and redistribute this, including at work.
* If you distribute it, or anything derived from it, **you must do so under the
  GPL v3 and make the source available**. Nobody can take this, close it, and
  ship it as a proprietary product.
* The GPL does **not** forbid charging money for a copy — no free-software
  licence does. What it guarantees is that whoever receives a copy gets the
  same freedoms and the source with it, which is what stops it being resold as
  a closed product.
* There is no warranty. This tool writes large files; check its output.
