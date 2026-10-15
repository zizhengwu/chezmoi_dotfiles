using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;

// The media reserve belongs to Streamlink. This controller only holds one
// transfer block and stops reading during startup/refill so that reserve grows.
public static class RestreamBuffer
{
    public static async Task PumpAsync(Stream input, Stream output, TimeSpan refill,
        TimeSpan stall, RestreamLogTee log, CancellationToken cancellation)
    {
        var block = new byte[65536];
        while (true)
        {
            // Keep this same read pending on timeout: starting another read can
            // lose bytes or reorder the binary stream.
            var read = input.ReadAsync(block, 0, block.Length, cancellation);
            int count;
            try
            {
                count = await read.WaitAsync(refill > TimeSpan.Zero ? stall : TimeSpan.FromSeconds(300),
                    cancellation).ConfigureAwait(false);
            }
            catch (TimeoutException) when (refill > TimeSpan.Zero)
            {
                log.WriteLine("restream", "Input stalled; waiting for media to return.");
                count = await read.WaitAsync(TimeSpan.FromSeconds(300), cancellation).ConfigureAwait(false);
                if (count > 0)
                {
                    log.WriteLine("restream", $"Media returned; refilling in Streamlink for {refill.TotalSeconds:g} seconds...");
                    await Task.Delay(refill, cancellation).ConfigureAwait(false);
                    log.WriteLine("restream", "Refill complete; resuming playback.");
                }
            }
            if (count == 0) return;
            // Backpressure from FFmpeg is normal, not source starvation. Only
            // time input reads, never output writes or the entire copy cycle.
            await output.WriteAsync(block, 0, count, cancellation).ConfigureAwait(false);
        }
    }

    public static async Task RunAsync(ProcessStartInfo sourceInfo, ProcessStartInfo sinkInfo,
        int bufferSeconds, RestreamLogTee log, CancellationToken cancellation)
    {
        while (!cancellation.IsCancellationRequested)
        {
            try
            {
                await RunOnceAsync(sourceInfo, sinkInfo, bufferSeconds, log, cancellation).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { return; }
            catch (Exception error)
            {
                log.WriteLine("restream", $"Publisher stopped: {error.Message}");
            }
            log.WriteLine("restream", "Restarting downloader and publisher in 5 seconds...");
            await Task.Delay(TimeSpan.FromSeconds(5), cancellation).ConfigureAwait(false);
        }
    }

    private static async Task RunOnceAsync(ProcessStartInfo sourceInfo, ProcessStartInfo sinkInfo,
        int bufferSeconds, RestreamLogTee log, CancellationToken cancellation)
    {
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        using var source = new Process { StartInfo = sourceInfo };
        using var sink = new Process { StartInfo = sinkInfo };
        Task sourceErrors = Task.CompletedTask, sinkErrors = Task.CompletedTask;
        Task copy = Task.CompletedTask;
        try
        {
            source.Start();
            sourceErrors = log.CopyAsync(source.StandardError.BaseStream, "streamlink");
            var first = new byte[1];
            var count = await source.StandardOutput.BaseStream.ReadAsync(first, 0, 1, stop.Token)
                .WaitAsync(TimeSpan.FromSeconds(300), stop.Token).ConfigureAwait(false);
            if (count == 0) throw new IOException("Streamlink ended before producing media.");
            if (bufferSeconds > 0)
            {
                log.WriteLine("restream", $"Buffering in Streamlink for {bufferSeconds} seconds...");
                await Task.Delay(TimeSpan.FromSeconds(bufferSeconds), stop.Token).ConfigureAwait(false);
            }
            sink.Start();
            sinkErrors = log.CopyAsync(sink.StandardError.BaseStream, "ffmpeg");
            log.WriteLine("restream", "Publishing at 1x speed.");
            await sink.StandardInput.BaseStream.WriteAsync(first, 0, 1, stop.Token).ConfigureAwait(false);
            await sink.StandardInput.BaseStream.FlushAsync(stop.Token).ConfigureAwait(false);
            copy = PumpAsync(source.StandardOutput.BaseStream, sink.StandardInput.BaseStream,
                TimeSpan.FromSeconds(bufferSeconds), TimeSpan.FromSeconds(10), log, stop.Token);
            var sinkExit = sink.WaitForExitAsync(stop.Token);
            var finished = await Task.WhenAny(copy, sinkExit).ConfigureAwait(false);
            cancellation.ThrowIfCancellationRequested();
            if (finished != copy)
                throw new IOException($"FFmpeg exited (code {sink.ExitCode}).");
            await copy.ConfigureAwait(false);
            sink.StandardInput.Close();
            // Allow FFmpeg to drain its small internal buffers on source EOF.
            await sinkExit.WaitAsync(TimeSpan.FromSeconds(10), stop.Token).ConfigureAwait(false);
            log.WriteLine("restream", "Streamlink reached end of stream.");
        }
        finally
        {
            stop.Cancel();
            Kill(sink);
            Kill(source);
            // Kill closes the pipes, including any read still pending at a timeout.
            try { await copy.ConfigureAwait(false); } catch { }
            try { await sourceErrors.ConfigureAwait(false); } catch { }
            try { await sinkErrors.ConfigureAwait(false); } catch { }
        }
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            process.WaitForExit();
        }
        catch (InvalidOperationException) { } // Process was never started/already gone.
    }
}
