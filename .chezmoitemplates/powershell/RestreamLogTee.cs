using System;
using System.IO;
using System.Text;
using System.Threading.Tasks;

public sealed class RestreamLogTee
{
    private readonly object gate = new object();
    private readonly Stream log;
    private Stream console;

    public RestreamLogTee(Stream log, Stream console)
    {
        this.log = log;
        this.console = console;
    }

    public void WriteLine(string source, string message)
    {
        lock (gate)
        {
            var bytes = Encoding.UTF8.GetBytes($"{DateTime.Now:o} [{source}] {message}\n");
            log.Write(bytes, 0, bytes.Length);
            log.Flush();
            if (console == null) return;
            try
            {
                console.Write(bytes, 0, bytes.Length);
                console.Flush();
            }
            catch (IOException) { console = null; }
            catch (ObjectDisposedException) { console = null; }
        }
    }

    public async Task CopyAsync(Stream input, string source)
    {
        using (var reader = new StreamReader(input, Encoding.UTF8, true, 4096, leaveOpen: true))
        {
            string line;
            while ((line = await reader.ReadLineAsync()) != null)
                WriteLine(source, line);
        }
    }
}
