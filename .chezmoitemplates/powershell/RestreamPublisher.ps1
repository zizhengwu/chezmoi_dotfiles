# Background Streamlink-to-FFmpeg publisher; media stays in a binary pipe.
param($streamUrl, $quality, $streamlinkConfig, $site, $rtspUrl, $logFile,
    [ValidateRange(0, 300)][int]$BufferSeconds = 30)
$ErrorActionPreference = 'Stop'
# Use .NET tasks: PowerShell callbacks on IO threads have no runspace.
Add-Type -Path (Join-Path $PSScriptRoot 'RestreamLogTee.cs'), (Join-Path $PSScriptRoot 'RestreamBuffer.cs')
$consoleError = [Console]::OpenStandardError()
$sourceInfo = [Diagnostics.ProcessStartInfo]::new()
$sinkInfo = [Diagnostics.ProcessStartInfo]::new()
$sinkLog = [IO.FileStream]::new($logFile, 'Append', 'Write', 'ReadWrite', 1)
$logger = [RestreamLogTee]::new($sinkLog, $consoleError)
$cancellation = [Threading.CancellationTokenSource]::new()
try {
    $sourceInfo.FileName = (Get-Command streamlink -CommandType Application | Select-Object -First 1).Source
    $sinkInfo.FileName = (Get-Command ffmpeg -CommandType Application | Select-Object -First 1).Source
    foreach ($info in @($sourceInfo, $sinkInfo)) {
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardError = $true
    }
    $sourceInfo.RedirectStandardOutput = $true
    $sinkInfo.RedirectStandardInput = $true
    foreach ($argument in @($streamUrl, $quality, '--config', $streamlinkConfig, '--stdout')) {
        $sourceInfo.ArgumentList.Add($argument)
    }
    # Twitch's MPEG-TS AAC lacks the global headers required by RTSP, too.
    $codecArguments = if ($site -in @('youtube', 'twitch')) { @('-c:v', 'copy', '-c:a', 'aac', '-b:a', '160k', '-flags:a', '+global_header') } else { @('-c', 'copy') }
    # FFmpeg 8.1 can repeatedly reset its per-track pacing after a long stall
    # with catchup exactly 1, yielding slow playback. Allow bounded 5% catchup.
    foreach ($argument in (@('-nostdin', '-hide_banner', '-loglevel', 'warning', '-readrate', '1', '-readrate_initial_burst', '0', '-readrate_catchup', '1.05', '-i', 'pipe:0', '-map', '0:v:0', '-map', '0:a:0') + $codecArguments + @('-rtsp_transport', 'tcp', '-f', 'rtsp', $rtspUrl))) {
        $sinkInfo.ArgumentList.Add($argument)
    }
    $runTask = [RestreamBuffer]::RunAsync($sourceInfo, $sinkInfo, $BufferSeconds, $logger, $cancellation.Token)
    # Keep PowerShell interruptible so Ctrl+C can cancel and clean up both children.
    while (-not $runTask.IsCompleted) { Start-Sleep -Milliseconds 200 }
    $null = $runTask.GetAwaiter().GetResult()
} catch {
    $publisherError = $_ | Out-String
} finally {
    $cancellation.Cancel()
    if ($runTask) { try { $null = $runTask.GetAwaiter().GetResult() } catch {} }
    try {
        if ($publisherError) {
            foreach ($line in ($publisherError -split '\r?\n')) {
                $logger.WriteLine('restream', $line)
            }
        }
    } finally {
        $sinkLog.Dispose()
        $cancellation.Dispose()
    }
}
