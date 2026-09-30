# Background Streamlink-to-FFmpeg publisher; media stays in a binary pipe.
param($streamUrl, $quality, $streamlinkConfig, $offsetConfig, $site, $rtspUrl, $logFile)
$ErrorActionPreference = 'Stop'
# Use .NET tasks: PowerShell callbacks on IO threads have no runspace.
Add-Type -Path (Join-Path $PSScriptRoot 'RestreamLogTee.cs')
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
