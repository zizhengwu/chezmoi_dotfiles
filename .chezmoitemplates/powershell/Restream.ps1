function restream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Url,

        [string]$Quality = "best",

        [string]$Proxy = 'socks5h://127.0.0.1:7890'
    )

    $config = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\bluenviron.mediamtx_Microsoft.Winget.Source_8wekyb3d8bbwe\mediamtx.yml"

    # Start one shared MediaMTX instance if it isn't already running.
    if (-not (Get-Process mediamtx -ErrorAction SilentlyContinue)) {
        Start-Process mediamtx.exe `
            -ArgumentList @($config) `
            -WindowStyle Hidden

        Start-Sleep -Milliseconds 700
    }

    foreach ($streamUrl in $Url) {
        $u = [Uri]$streamUrl

        # Generate a readable unique MediaMTX path.
        # www.huya.com/dota2sdn       -> huya-dota2sdn
        # live.bilibili.com/12413170 -> bilibili-12413170
        $streamHost = $u.Host -replace '^(www|live)\.', ''
        $site = ($streamHost -split '\.')[0]

        $room = ($u.AbsolutePath.Trim('/') -split '/')[-1]
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

            if ($oldPid -and (Get-Process -Id $oldPid -ErrorAction SilentlyContinue)) {
                $publisherRunning = $true
            }
        }

        if (-not $publisherRunning) {
            $urlEsc  = $streamUrl.Replace("'", "''")
            $qualEsc = $Quality.Replace("'", "''")
            $logEsc  = $logFile.Replace("'", "''")
            $streamlinkLogEsc = $streamlinkLog.Replace("'", "''")
            $proxyEsc = $Proxy.Replace("'", "''")

            # Separate stderr files: PowerShell locks each redirection target.
            # Keep FFmpeg on one line to avoid nested here-string backtick escaping.
            $publisherCommand = @"
`$ErrorActionPreference = 'Stop'
try {
    streamlink '$urlEsc' '$qualEsc' --http-proxy '$proxyEsc' --http-timeout 15 --stdout 2>> '$streamlinkLogEsc' |
        ffmpeg -nostdin -hide_banner -loglevel warning -i pipe:0 -map 0:v:0 -map 0:a:0 -c copy -rtsp_transport tcp -f rtsp '$rtspUrl' 2>> '$logEsc'
} catch {
    `$_ | Out-String | Add-Content '$logEsc'
    exit 1
}
"@

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
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            if (-not (Get-Process -Id (Get-Content $pidFile) -ErrorAction SilentlyContinue)) {
                Write-Error "Publisher exited for $streamUrl. See $logFile and $streamlinkLog."
                break
            }
            & ffprobe -v error -rtsp_transport tcp -timeout 2000000 -analyzeduration 0 -probesize 32 -show_entries stream=codec_name -of csv=p=0 $rtspUrl 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $ready = $true
                break
            }
            Start-Sleep -Milliseconds 500
        } while ([DateTime]::UtcNow -lt $deadline)

        if (-not $ready) {
            Write-Warning "Stream is not ready. See $logFile and $streamlinkLog."
            continue
        }

        # MPV is also independent, so the PowerShell prompt returns immediately.
        Start-Process mpv.exe `
            -ArgumentList @(
                "--rtsp-transport=tcp",
                "rtsp://127.0.0.1:8554/$path"
            )

        Write-Host "Stream: $path"
        Write-Host "RTSP:   rtsp://127.0.0.1:8554/$path"
        Write-Host "iPad:   http://192.168.50.200:8888/$path/"
        Write-Host "Log:    $logFile"
        Write-Host "Source: $streamlinkLog"
    }
}
