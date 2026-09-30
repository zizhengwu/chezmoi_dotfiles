function restream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Url,

        [string]$Quality = "best",

        [switch]$Restart
    )

    # Shared source buffering/retry settings, independent of the viewing player.
    $streamlinkConfig = Join-Path $HOME 'scoop/persist/streamlink/config-rtsp'

    $config = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\bluenviron.mediamtx_Microsoft.Winget.Source_8wekyb3d8bbwe\mediamtx.yml"

    # Start one shared MediaMTX instance if it isn't already running.
    if (-not (Get-Process mediamtx -ErrorAction SilentlyContinue)) {
        Start-Process mediamtx.exe `
            -ArgumentList @($config) `
            -WindowStyle Hidden

        Start-Sleep -Milliseconds 700
    }

    # Runs in a background PowerShell process sharing the console; keep media as bytes.
    $publish = {
        param($streamUrl, $quality, $streamlinkConfig, $offsetConfig, $site, $rtspUrl, $logFile)
        $ErrorActionPreference = 'Stop'
        # Use .NET tasks: PowerShell callbacks on IO threads have no runspace.
        Add-Type -TypeDefinition @'
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
'@
        $consoleError = [Console]::OpenStandardError()
        $source = [Diagnostics.Process]::new()
        $sink = [Diagnostics.Process]::new()
        $sinkLog = [IO.FileStream]::new($logFile, 'Append', 'Write', 'ReadWrite', 1)
        $logger = [RestreamLogTee]::new($sinkLog, $consoleError)
        try {
            $source.StartInfo.FileName = (Get-Command streamlink -CommandType Application).Source
            $sink.StartInfo.FileName = (Get-Command ffmpeg -CommandType Application).Source
            foreach ($process in @($source, $sink)) {
                $process.StartInfo.UseShellExecute = $false
                $process.StartInfo.CreateNoWindow = $true
                $process.StartInfo.RedirectStandardError = $true
            }
            $source.StartInfo.RedirectStandardOutput = $true
            $sink.StartInfo.RedirectStandardInput = $true
            foreach ($argument in @($streamUrl, $quality, '--config', $streamlinkConfig, '--stdout')) {
                $source.StartInfo.ArgumentList.Add($argument)
            }
            if ($offsetConfig) {
                $source.StartInfo.ArgumentList.Add('--config')
                $source.StartInfo.ArgumentList.Add($offsetConfig)
            }
            # Twitch's MPEG-TS AAC lacks the global headers required by RTSP, too.
            $codecArguments = if ($site -in @('youtube', 'twitch')) { @('-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-flags:a', '+global_header') } else { @('-c', 'copy') }
            foreach ($argument in (@('-nostdin', '-hide_banner', '-loglevel', 'warning', '-readrate', '1', '-readrate_initial_burst', '0', '-readrate_catchup', '1', '-i', 'pipe:0', '-map', '0:v:0', '-map', '0:a:0') + $codecArguments + @('-rtsp_transport', 'tcp', '-f', 'rtsp', $rtspUrl))) {
                $sink.StartInfo.ArgumentList.Add($argument)
            }
            $null = $source.Start()
            $sourceErrors = $logger.CopyAsync($source.StandardError.BaseStream, 'streamlink')
            # Publish as soon as media arrives; Streamlink owns the HLS offset.
            $firstByte = $source.StandardOutput.BaseStream.ReadByte()
            if ($firstByte -lt 0) { throw 'Streamlink ended before producing media.' }
            $logger.WriteLine('restream', 'Publishing at 1x speed.')
            $null = $sink.Start()
            $sinkErrors = $logger.CopyAsync($sink.StandardError.BaseStream, 'ffmpeg')
            $sink.StandardInput.BaseStream.WriteByte([byte]$firstByte)
            # Flush the saved header byte before the asynchronous bulk copy.
            $sink.StandardInput.BaseStream.Flush()
            $null = $source.StandardOutput.BaseStream.CopyToAsync($sink.StandardInput.BaseStream).GetAwaiter().GetResult()
            $sink.StandardInput.Close()
            $source.WaitForExit()
            $sink.WaitForExit()
        } catch {
            $publisherError = $_ | Out-String
        } finally {
            foreach ($process in @($source, $sink)) {
                try {
                    if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
                } catch {}
            }
            foreach ($task in @($sourceErrors, $sinkErrors)) {
                if ($task) { try { $task.GetAwaiter().GetResult() } catch {} }
            }
            try {
                if ($publisherError) {
                    foreach ($line in ($publisherError -split '\r?\n')) {
                        $logger.WriteLine('restream', $line)
                    }
                }
            } finally {
                $sinkLog.Dispose()
            }
        }
    }

    foreach ($streamUrl in $Url) {
        if ($streamUrl -notmatch '^https?://') { $streamUrl = "https://$streamUrl" }
        $u = [Uri]$streamUrl

        # Generate a readable unique MediaMTX path.
        # www.huya.com/dota2sdn       -> huya-dota2sdn
        # live.bilibili.com/12413170 -> bilibili-12413170
        # www.youtube.com/@venruki/live -> youtube-venruki
        $streamHost = $u.Host -replace '^(www|live)\.', ''
        $site = ($streamHost -split '\.')[0]
        # Load the shared HLS offset only for YouTube and Twitch.
        $offsetConfig = if ($u.Host -match '(^|\.)(youtube\.com|youtu\.be|twitch\.tv)$') {
            Join-Path (Split-Path $streamlinkConfig) 'config-rtsp-delayed'
        } else { $null }

        $room = ($u.AbsolutePath.Trim('/') -split '/')[-1]
        if ($site -eq 'youtube' -and $u.AbsolutePath -match '^/(?:@([^/]+)|(?:channel|c|user)/([^/]+))/live/?$') {
            $room = if ($Matches[1]) { $Matches[1] } else { $Matches[2] }
        }
        if (-not $room) {
            $room = "stream"
        }

        $path = ("$site-$room" -replace '[^A-Za-z0-9_-]', '-').ToLowerInvariant()

        $pidFile = Join-Path $env:TEMP "restream-$path.pid"
        $logFile = Join-Path $env:TEMP "restream-$path.log"
        $rtspUrl = "rtsp://127.0.0.1:8554/$path"

        # Don't start a second publisher if this stream is already running.
        $publisherRunning = $false

        if (Test-Path $pidFile) {
            $oldPid = Get-Content $pidFile -ErrorAction SilentlyContinue

            if ($oldPid -match '^\d+$') {
                $oldProcess = Get-CimInstance Win32_Process -Filter "ProcessId = $oldPid"
                # Verify ownership before reusing a PID or stopping its process tree.
                if ($oldProcess.Name -eq 'pwsh.exe' -and $oldProcess.CommandLine -match '-EncodedCommand\s+(\S+)') {
                    $oldCommand = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
                    if ($oldCommand.Contains("'$rtspUrl'")) {
                        if ($Restart) {
                            $oldPublisher = Get-Process -Id $oldPid
                            $oldPublisher.Kill($true)
                            $oldPublisher.WaitForExit()
                        } else {
                            $publisherRunning = $true
                        }
                    }
                }
            }
        }

        if (-not $publisherRunning) {
            $arguments = @($streamUrl, $Quality, $streamlinkConfig, $offsetConfig, $site, $rtspUrl, $logFile) | ForEach-Object {
                "'" + "$($_)".Replace("'", "''") + "'"
            }
            $publisherCommand = "& { $publish } $($arguments -join ' ')"

            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($publisherCommand)
            )

            $publisher = Start-Process pwsh `
                -ArgumentList "-NoProfile", "-EncodedCommand", $encoded `
                -NoNewWindow `
                -PassThru

            Set-Content $pidFile $publisher.Id

        }

        # A fixed delay can open MPV before MediaMTX has a stream to serve.
        $ready = $false
        Write-Host 'Waiting for publisher...'
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            if (-not (Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue)) {
                Write-Error "Publisher exited for $streamUrl. See $logFile."
                break
            }
            & ffprobe -v error -rtsp_transport tcp -timeout 2000000 -analyzeduration 0 -probesize 32 -show_entries stream=codec_name -of csv=p=0 $rtspUrl 2>$null | Out-Null
            $ready = $LASTEXITCODE -eq 0
            if ($ready) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $ready) {
            Write-Warning "Stream is not ready. See $logFile."
            continue
        }

        # MPV is also independent, so the PowerShell prompt returns immediately.
        Start-Process mpv.exe -ArgumentList '--rtsp-transport=tcp', $rtspUrl

        Write-Host "Stream: $path"
        Write-Host "RTSP:   rtsp://127.0.0.1:8554/$path"
        Write-Host "iPad:   http://192.168.50.200:8888/$path/"
        Write-Host "Log:    $logFile"
    }
}
