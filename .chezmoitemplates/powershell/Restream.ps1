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
    $bufferSetting = Select-String -LiteralPath $streamlinkConfig -Pattern '^# restream-buffer-seconds=(\d+)\s*$' -ErrorAction Stop
    if (-not $bufferSetting) { throw "Missing restream-buffer-seconds in $streamlinkConfig" }
    $bufferSeconds = [int]$bufferSetting.Matches[0].Groups[1].Value

    $config = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\bluenviron.mediamtx_Microsoft.Winget.Source_8wekyb3d8bbwe\mediamtx.yml"

    # Start one shared MediaMTX instance if it isn't already running.
    if (-not (Get-Process mediamtx -ErrorAction SilentlyContinue)) {
        Start-Process mediamtx.exe `
            -ArgumentList @($config) `
            -WindowStyle Hidden

        Start-Sleep -Milliseconds 700
    }

    # Runs in a detached PowerShell process; keep media as bytes throughout.
    $publish = {
        param($streamUrl, $quality, $streamlinkConfig, $bufferSeconds, $site, $rtspUrl, $logFile, $streamlinkLog)
        $ErrorActionPreference = 'Stop'
        $source = [Diagnostics.Process]::new()
        $sink = [Diagnostics.Process]::new()
        $sourceLog = [IO.FileStream]::new($streamlinkLog, 'Append', 'Write', 'ReadWrite', 1)
        $sinkLog = [IO.FileStream]::new($logFile, 'Append', 'Write', 'ReadWrite', 1)
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
            $codecArguments = if ($site -eq 'youtube') { @('-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-flags:a', '+global_header') } else { @('-c', 'copy') }
            foreach ($argument in (@('-nostdin', '-hide_banner', '-loglevel', 'warning', '-readrate', '1', '-readrate_initial_burst', '0', '-readrate_catchup', '1', '-i', 'pipe:0', '-map', '0:v:0', '-map', '0:a:0') + $codecArguments + @('-rtsp_transport', 'tcp', '-f', 'rtsp', $rtspUrl))) {
                $sink.StartInfo.ArgumentList.Add($argument)
            }
            $null = $source.Start()
            $sourceErrors = $source.StandardError.BaseStream.CopyToAsync($sourceLog)
            # Start the delay only after actual media arrives. While stdout is blocked,
            # Streamlink's download thread continues filling its bounded ring buffer.
            $firstByte = $source.StandardOutput.BaseStream.ReadByte()
            if ($firstByte -lt 0) { throw 'Streamlink ended before producing media.' }
            $message = [Text.Encoding]::UTF8.GetBytes("$([DateTime]::Now.ToString('o')) Buffering $bufferSeconds seconds before publication.`n")
            $sinkLog.Write($message, 0, $message.Length)
            Start-Sleep -Seconds $bufferSeconds
            $message = [Text.Encoding]::UTF8.GetBytes("$([DateTime]::Now.ToString('o')) Publishing at 1x speed.`n")
            $sinkLog.Write($message, 0, $message.Length)
            $null = $sink.Start()
            $sinkErrors = $sink.StandardError.BaseStream.CopyToAsync($sinkLog)
            $sink.StandardInput.BaseStream.WriteByte([byte]$firstByte)
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
            $sourceLog.Dispose()
            $sinkLog.Dispose()
            if ($publisherError) { Add-Content $logFile $publisherError }
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
        $streamlinkLog = Join-Path $env:TEMP "restream-$path-streamlink.log"
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
            $arguments = @($streamUrl, $Quality, $streamlinkConfig, $bufferSeconds, $site, $rtspUrl, $logFile, $streamlinkLog) | ForEach-Object {
                "'" + "$($_)".Replace("'", "''") + "'"
            }
            $publisherCommand = "& { $publish } $($arguments -join ' ')"

            $encoded = [Convert]::ToBase64String(
                [Text.Encoding]::Unicode.GetBytes($publisherCommand)
            )

            $publisher = Start-Process pwsh `
                -ArgumentList "-NoProfile", "-EncodedCommand", $encoded `
                -WindowStyle Hidden `
                -PassThru

            Set-Content $pidFile $publisher.Id

        }

        # A fixed delay can open MPV before MediaMTX has a stream to serve.
        $ready = $false
        Write-Host "Waiting for publisher (shared buffer: $bufferSeconds seconds)..."
        $deadline = [DateTime]::UtcNow.AddSeconds($bufferSeconds + 45)
        do {
            if (-not (Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue)) {
                Write-Error "Publisher exited for $streamUrl. See $logFile and $streamlinkLog."
                break
            }
            & ffprobe -v error -rtsp_transport tcp -timeout 2000000 -analyzeduration 0 -probesize 32 -show_entries stream=codec_name -of csv=p=0 $rtspUrl 2>$null | Out-Null
            $ready = $LASTEXITCODE -eq 0
            if ($ready) { break }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $ready) {
            Write-Warning "Stream is not ready. See $logFile and $streamlinkLog."
            continue
        }

        # MPV is also independent, so the PowerShell prompt returns immediately.
        Start-Process mpv.exe -ArgumentList '--rtsp-transport=tcp', $rtspUrl

        Write-Host "Stream: $path"
        Write-Host "RTSP:   rtsp://127.0.0.1:8554/$path"
        Write-Host "iPad:   http://192.168.50.200:8888/$path/"
        Write-Host "Log:    $logFile"
        Write-Host "Source: $streamlinkLog"
    }
}
