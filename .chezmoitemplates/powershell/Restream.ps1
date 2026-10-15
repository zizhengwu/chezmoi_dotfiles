# Return only a publisher whose decoded invocation belongs to this wrapper.
function Get-RestreamPublisher {
    param([string]$Name)
    $pidFile = Join-Path $env:TEMP "restream-$Name.pid"
    $publisherId = 0
    if (-not (Test-Path -LiteralPath $pidFile)) { return }
    if (-not [int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(), [ref]$publisherId) -or $publisherId -le 0) { return }
    $process = Get-Process -Id $publisherId -ErrorAction SilentlyContinue
    if (-not $process) { return }
    $info = Get-CimInstance Win32_Process -Filter "ProcessId = $publisherId" -ErrorAction SilentlyContinue
    if ($info.Name -ne 'pwsh.exe' -or $info.CommandLine -notmatch '-EncodedCommand\s+([^\s"]+)') { return }
    try {
        $command = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))
        $tokens = $null; $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseInput($command, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -or $ast.EndBlock.Statements.Count -ne 1) { return }
        $pipeline = $ast.EndBlock.Statements[0]
        if ($pipeline -isnot [Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1) { return }
        $invocation = $pipeline.PipelineElements[0]
        if ($invocation -isnot [Management.Automation.Language.CommandAst] -or $invocation.CommandElements.Count -ne 8 -or $invocation.Redirections.Count) { return }
        $values = @($invocation.CommandElements | ForEach-Object {
            if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
        })
        if ($values.Count -ne 8) { return }
        $allowedScripts = @(
            (Join-Path $PSScriptRoot 'RestreamPublisher.ps1')
            (Join-Path $HOME 'Documents/PowerShell/RestreamPublisher.ps1')
            (Join-Path $HOME 'Documents/WindowsPowerShell/RestreamPublisher.ps1')
        )
        if ($values[0] -notin $allowedScripts -or $values[5] -ne "rtsp://127.0.0.1:8554/$Name") { return }
        if ($process.HasExited) { return }
        return $process
    } catch { return }
}

function restream {
    <#
    .SYNOPSIS
    Start, list, or stop local restream publishers.
    .DESCRIPTION
    restream <url> and restream start <url> start a stream and open MPV.
    restream list returns objects describing tracked publishers (not playback health).
    restream stop <name> stops a publisher and its children; stop -All stops all tracked publishers.
    Stopping leaves the shared MediaMTX server, independent viewers, and logs intact.
    Stale PID records are shown in list and removed by stop. Supports -WhatIf.
    .EXAMPLE
    restream start https://www.youtube.com/@venruki/live -Restart
    .EXAMPLE
    restream list | Where-Object Status -eq Running
    .EXAMPLE
    restream stop youtube-venruki -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position=0, ValueFromRemainingArguments=$true)]
        [string[]]$Url,

        [string]$Quality = "best",

        # Startup/refill hold for YouTube and Twitch only; 0 disables both.
        [ValidateRange(0, 300)]
        [int]$BufferSeconds = 30,

        [switch]$Restart,

        [switch]$All
    )

    if (-not $Url) {
        Write-Host 'Usage: restream [start] <url> ... [-Restart] [-Quality best] [-BufferSeconds 30]'
        Write-Host '       restream list'
        Write-Host '       restream stop <name> ... | restream stop -All'
        return
    }
    $verb = 'start'
    if ($Url[0] -in @('start', 'list', 'stop')) {
        $verb = $Url[0].ToLowerInvariant()
        $Url = @($Url | Select-Object -Skip 1)
    }
    if ($All -and $verb -ne 'stop') { throw '-All is only valid with restream stop.' }
    if ($verb -ne 'start' -and ($Restart -or $PSBoundParameters.ContainsKey('Quality') -or $PSBoundParameters.ContainsKey('BufferSeconds'))) {
        throw '-Restart, -Quality, and -BufferSeconds are only valid when starting streams.'
    }
    if ($verb -eq 'list') {
        if ($Url.Count) { throw 'Usage: restream list' }
        Get-ChildItem -LiteralPath $env:TEMP -Filter 'restream-*.pid' -File | Sort-Object Name | ForEach-Object {
            $name = $_.BaseName.Substring('restream-'.Length)
            $publisher = Get-RestreamPublisher $name
            [pscustomobject]@{
                Name = $name
                Status = if ($publisher) { 'Running' } else { 'Stale' }
                ProcessId = if ($publisher) { $publisher.Id } else { $null }
                RTSP = "rtsp://127.0.0.1:8554/$name"
                LogFile = Join-Path $env:TEMP "restream-$name.log"
            }
        }
        return
    }
    if ($verb -eq 'stop') {
        if (($All -and $Url.Count) -or (-not $All -and -not $Url.Count)) { throw 'Usage: restream stop <name> ... OR restream stop -All' }
        $names = if ($All) {
            Get-ChildItem -LiteralPath $env:TEMP -Filter 'restream-*.pid' -File | ForEach-Object { $_.BaseName.Substring('restream-'.Length) }
        } else { $Url }
        # Validate all targets before changing anything; names are exact, never wildcards.
        foreach ($name in $names) {
            if ($name -notmatch '^[a-zA-Z0-9_-]+$') { throw "Invalid stream name '$name'. Use names from restream list." }
        }
        foreach ($name in ($names | Select-Object -Unique)) {
            $pidFile = Join-Path $env:TEMP "restream-$name.pid"
            if (-not (Test-Path -LiteralPath $pidFile)) { Write-Warning "No tracked stream named '$name'."; continue }
            if ($PSCmdlet.ShouldProcess($name, 'Stop publisher and remove PID record')) {
                $publisher = Get-RestreamPublisher $name
                if ($publisher) {
                    $publisher.Kill($true)
                    $publisher.WaitForExit()
                }
                Remove-Item -LiteralPath $pidFile -ErrorAction Stop
                if ($publisher) { Write-Host "Stopped: $name" }
                else { Write-Host "Removed stale record: $name" }
            }
        }
        return
    }
    if (-not $Url.Count) { throw 'Usage: restream start <url> ...' }
    # Decide before starting MediaMTX so -WhatIf has no process side effects.
    $Url = @($Url | Where-Object { $PSCmdlet.ShouldProcess($_, 'Start/reuse publisher and open MPV') })
    if (-not $Url.Count) { return }

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
        $startupBufferSeconds = if ($u.Host -match '(^|\.)(youtube\.com|youtu\.be|twitch\.tv)$') {
            $BufferSeconds
        } else { 0 }

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
        $rtspUrl = "rtsp://127.0.0.1:8554/$path"

        # Don't start a second publisher if this stream is already running.
        $publisherRunning = $false

        $oldPublisher = Get-RestreamPublisher $path
        if ($oldPublisher) {
            if ($Restart) {
                $oldPublisher.Kill($true)
                $oldPublisher.WaitForExit()
            } else {
                $publisherRunning = $true
            }
        }

        if (-not $publisherRunning) {
            $arguments = @($streamUrl, $Quality, $streamlinkConfig, $site, $rtspUrl, $logFile, $startupBufferSeconds) | ForEach-Object {
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
        # Allow source discovery/probing time in addition to the startup hold.
        $deadline = [DateTime]::UtcNow.AddSeconds(45 + $startupBufferSeconds)
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
        # Reload if a long refill or publisher restart closes the RTSP session.
        Start-Process mpv.exe -ArgumentList '--rtsp-transport=tcp', '--loop-playlist=force', $rtspUrl

        Write-Host "Stream: $path"
        Write-Host "RTSP:   rtsp://127.0.0.1:8554/$path"
        Write-Host "iPad:   http://192.168.50.200:8888/$path/"
        Write-Host "Log:    $logFile"
    }
}
