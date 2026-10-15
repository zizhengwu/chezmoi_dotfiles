# Restream refill controller

`RestreamBuffer.cs` controls the binary pipe between Streamlink and FFmpeg. It
keeps only a 64 KiB transfer block; Streamlink owns the substantial reserve.
The `restream` wrapper enables startup/refill holds only for YouTube and Twitch.
`-BufferSeconds 0` disables both holds.

- Startup: read the first byte, hold for `BufferSeconds`, then start FFmpeg.
- Playing: forward bytes with backpressure from FFmpeg's 1x consumption.
- Input starvation: after a read waits 10 seconds, log the stall and keep that
  same read pending. Slow output writes do not trigger rebuffering.
- Refill: when that read finally returns media, hold it and stop reading for
  `BufferSeconds`. Streamlink can keep downloading into its ring buffer.
- EOF/failure: restart both downloader and publisher after 5 seconds, including
  initial prebuffering. This can require viewers to reconnect.
- No input for approximately 300 seconds: restart rather than wait forever.
- Cancellation: cancel pending operations and terminate owned process trees.

The hold approximates a media reserve; it does not measure playable seconds.
An unstable connection can stall again during the hold. No timestamp parsing,
seamless splicing across downloader restarts, or second large buffer is added.
FFmpeg uses `-readrate 1 -readrate_catchup 1.05`: normal speed with bounded 5%
catchup after stalls. Exactly 1 for catchup caused repeated pacing resets and
slow playback with FFmpeg 8.1 in the synthetic media test. MediaMTX and viewer
timeouts must tolerate the refill pause (the current MediaMTX setup has a
300-second read timeout). RTSP readers can nevertheless disconnect during long
gaps. The wrapper launches MPV with `--loop-playlist=force` to reload on EOF or
connection failure; closing MPV still quits it normally.

## Checks

From the repository root, on Windows with PowerShell 7:

```powershell
pwsh -NoProfile -File .chezmoitemplates/powershell/tests/RestreamBuffer.Tests.ps1
uv run --no-project python .chezmoitemplates/powershell/tests/RestreamBuffer.Integration.py
```

The first check uses actual local pipes and child processes to test repeated
refills, byte integrity, backpressure, cancellation, EOF, disabling buffering,
and restart after process failure.

The integration check needs Streamlink, FFmpeg, MPV and MediaMTX on PATH. It generates
synthetic audio/video, serves a local HLS source, launches an isolated MediaMTX
instance on a free port, and exercises the actual publisher with the default
30-second holds. It cuts source access until input stalls, restores it, verifies
the refill pause, and checks headless MPV resumes playback (including automatic
RTSP reconnection if necessary). A parallel FFmpeg reader provides diagnostics.
It uses no
external network or production settings. Allow approximately 2â€“3 minutes.
Artifacts are written beneath `%TEMP%/restream-refill-*`; owned processes are
terminated on completion. This does not validate the iPad browser or
authentication after a real proxy exit-IP change.
