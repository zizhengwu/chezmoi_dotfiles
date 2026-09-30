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
            $publisherScript = (Join-Path $PSScriptRoot 'RestreamPublisher.ps1').Replace("'", "''")
            $publisherCommand = "& '$publisherScript' $($arguments -join ' ')"

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
