using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

public static class RestreamBufferTests
{
    private static readonly TimeSpan Stall = TimeSpan.FromMilliseconds(150);
    private static readonly TimeSpan Refill = TimeSpan.FromMilliseconds(300);

    private sealed class Capture : MemoryStream
    {
        public int Delay;
        public override async Task WriteAsync(byte[] bytes, int offset, int count, CancellationToken token)
        {
            if (Delay > 0) await Task.Delay(Delay, token);
            lock (this) base.Write(bytes, offset, count);
        }
        public override void Write(byte[] bytes, int offset, int count)
        {
            lock (this) base.Write(bytes, offset, count);
        }
        public byte[] Bytes { get { lock (this) return ToArray(); } }
        public string Text => Encoding.UTF8.GetString(Bytes);
    }

    private sealed class Pipes : IDisposable
    {
        public readonly NamedPipeServerStream Input;
        public readonly NamedPipeClientStream Writer;
        public Pipes()
        {
            var name = "restream-test-" + Guid.NewGuid();
            Input = new NamedPipeServerStream(name, PipeDirection.In, 1,
                PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
            Writer = new NamedPipeClientStream(".", name, PipeDirection.Out, PipeOptions.Asynchronous);
        }
        public Task Connect() => Task.WhenAll(Input.WaitForConnectionAsync(), Writer.ConnectAsync());
        public void Dispose() { Writer.Dispose(); Input.Dispose(); }
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    private static async Task Until(Func<bool> condition)
    {
        var deadline = Stopwatch.StartNew();
        while (!condition())
        {
            if (deadline.Elapsed.TotalSeconds > 10) throw new Exception("Condition timed out");
            await Task.Delay(10);
        }
    }

    private static async Task ExpectCancelled(Task task)
    {
        try { await task.WaitAsync(TimeSpan.FromSeconds(5)); }
        catch (OperationCanceledException) { return; }
        throw new Exception("Expected cancellation");
    }

    public static async Task RunAsync(string pwsh)
    {
        // Actual OS pipes: timeout leaves the SAME read pending, repeated refills
        // preserve byte order, and refill time starts only after data returns.
        using (var pipes = new Pipes())
        using (var output = new Capture())
        using (var log = new Capture())
        using (var stop = new CancellationTokenSource(TimeSpan.FromSeconds(10)))
        {
            await pipes.Connect();
            var pump = RestreamBuffer.PumpAsync(pipes.Input, output, Refill, Stall,
                new RestreamLogTee(log, Stream.Null), stop.Token);
            await pipes.Writer.WriteAsync(new byte[] { 0, 255, 1 });
            await Until(() => output.Bytes.Length == 3);
            for (byte round = 0; round < 2; round++)
            {
                int prior = output.Bytes.Length;
                int expectedStalls = round + 1;
                await Until(() => log.Text.Split("Input stalled").Length - 1 == expectedStalls);
                await Task.Delay(350); // Longer than refill; still no media.
                await pipes.Writer.WriteAsync(new byte[] { (byte)(round + 2) });
                await Until(() => log.Text.Split("Media returned").Length - 1 == expectedStalls);
                await Task.Delay(70);
                Check(output.Bytes.Length == prior, "Refill timer started before media returned");
                await Until(() => output.Bytes.Length == prior + 1);
            }
            pipes.Writer.Dispose();
            await pump.WaitAsync(TimeSpan.FromSeconds(5));
            Check(output.Bytes.SequenceEqual(new byte[] { 0, 255, 1, 2, 3 }), "Bytes lost/reordered");
        }
        Console.WriteLine("PASS repeated outages, refill timing, binary integrity and EOF");

        // A slow consumer must never be mistaken for upstream starvation.
        using (var input = new MemoryStream(Enumerable.Range(0, 200000).Select(i => (byte)i).ToArray()))
        using (var output = new Capture { Delay = 200 })
        using (var log = new Capture())
        {
            await RestreamBuffer.PumpAsync(input, output, Refill, Stall,
                new RestreamLogTee(log, Stream.Null), CancellationToken.None);
            Check(output.Bytes.SequenceEqual(input.ToArray()), "Backpressure corrupted bytes");
            Check(!log.Text.Contains("stalled"), "Output backpressure triggered refill");
        }
        Console.WriteLine("PASS slow output and multi-block transfer");

        foreach (bool duringRefill in new[] { false, true })
        {
            using var pipes = new Pipes();
            using var output = new Capture();
            using var log = new Capture();
            using var stop = new CancellationTokenSource();
            await pipes.Connect();
            var pump = RestreamBuffer.PumpAsync(pipes.Input, output, TimeSpan.FromSeconds(30), Stall,
                new RestreamLogTee(log, Stream.Null), stop.Token);
            await Until(() => log.Text.Contains("Input stalled"));
            if (duringRefill)
            {
                await pipes.Writer.WriteAsync(new byte[] { 1 });
                await Until(() => log.Text.Contains("Media returned"));
            }
            stop.Cancel();
            await ExpectCancelled(pump);
            Check(output.Bytes.Length == 0, "Cancellation forwarded held bytes");
        }
        Console.WriteLine("PASS cancellation during pending read and refill");

        using (var pipes = new Pipes())
        using (var output = new Capture())
        using (var log = new Capture())
        {
            await pipes.Connect();
            var pump = RestreamBuffer.PumpAsync(pipes.Input, output, Refill, Stall,
                new RestreamLogTee(log, Stream.Null), CancellationToken.None);
            await Until(() => log.Text.Contains("Input stalled"));
            pipes.Writer.Dispose();
            await pump.WaitAsync(TimeSpan.FromSeconds(2));
            Check(!log.Text.Contains("Media returned"), "EOF incorrectly triggered refill");
        }
        Console.WriteLine("PASS EOF while stalled");

        using (var pipes = new Pipes())
        using (var output = new Capture())
        using (var log = new Capture())
        {
            await pipes.Connect();
            var pump = RestreamBuffer.PumpAsync(pipes.Input, output, TimeSpan.Zero, Stall,
                new RestreamLogTee(log, Stream.Null), CancellationToken.None);
            await Task.Delay(400);
            await pipes.Writer.WriteAsync(new byte[] { 5 });
            await Until(() => output.Bytes.Length == 1);
            pipes.Writer.Dispose();
            await pump;
            Check(log.Bytes.Length == 0, "Disabled buffering triggered refill");
        }
        Console.WriteLine("PASS disabled buffering");

        // Exercise process supervision using real children, without network access.
        foreach (bool sinkFails in new[] { true, false })
        {
            using var log = new Capture();
            using var stop = new CancellationTokenSource();
            var source = Info(pwsh, "$s=[Console]::OpenStandardOutput(); $s.Write([byte[]](1,2,3),0,3); $s.Flush(); "
                + (sinkFails ? "Start-Sleep -Seconds 60" : "exit 0"), false);
            var sink = Info(pwsh, sinkFails ? "exit 9" : "[Console]::OpenStandardInput().CopyTo([IO.Stream]::Null)", true);
            var run = RestreamBuffer.RunAsync(source, sink, 0, new RestreamLogTee(log, Stream.Null), stop.Token);
            try
            {
                await Until(() => log.Text.Split("Publishing at 1x").Length - 1 >= 2);
                Check(log.Text.Contains("Restarting downloader"), "Did not restart");
            }
            catch { Console.WriteLine(log.Text); throw; }
            finally
            {
                stop.Cancel();
                try { await run.WaitAsync(TimeSpan.FromSeconds(5)); } catch (OperationCanceledException) { }
            }
        }
        Console.WriteLine("PASS restart after sink failure and source EOF, supervisor cancellation");
    }

    private static ProcessStartInfo Info(string pwsh, string script, bool sink)
    {
        var info = new ProcessStartInfo(pwsh) {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardError = true,
            RedirectStandardInput = sink, RedirectStandardOutput = !sink
        };
        info.ArgumentList.Add("-NoProfile");
        info.ArgumentList.Add("-EncodedCommand");
        info.ArgumentList.Add(Convert.ToBase64String(Encoding.Unicode.GetBytes(script)));
        return info;
    }
}
